#!/usr/bin/env python3
"""STEP import and export (stepread.zig, step.zig) and the B-rep kernel under
them (nurbs.zig, brep.zig, btess.zig), standalone.

  * Fixtures made by BeeModel (features with cad.kernel on: planes,
    cylinders, cones, spheres, tori, a pocket, holes, a boss, a traced
    cylinder-cylinder hole, a shell, fillets, chamfers; moved, turned and
    coloured objects, a name with a quote; one solid alone and assemblies;
    four length units) are imported again into scenes in metres, millimetres
    and inches: every solid comes back with its place, turn and colour, its
    mesh and its brep() values (volume, area, faces, edges, vertices, loops,
    valid, triangles, tessvolume, watertight, surface kinds) as made, scaled
    by the units (lengths, areas, volumes); exported again in the same units,
    the same file; in other units, export -> import -> export the same file.
    The same solids with B-spline surfaces and curves in place of planes and
    lines: the same volumes, areas and topology.
  * Real-world files (AP203 / AP214 from other CAD systems: STEP_REAL=dir,
    default the scratch copy, skipped when absent): import cleanly, solids,
    export -> import -> export the same file.
  * Damaged and garbage STEP (truncated, bytes flipped, spliced, deep
    nesting, huge ids and counts, reference cycles, NaN and infinite reals,
    empty, binary): BeeModel never crashes or hangs, and says one of
    "imported", "no solids in", "could not read" for each.
  * Undo and files: an import undone and redone, the export follows the
    objects; a saved and reopened scene has no B-rep.
  * The window: File > Import / Export list STEP, the file browser keeps
    .step / .stp; dropped .step files import.
  * Timings (a release build, one CPU): reading, tessellating, writing.

    python3 tests/step.py BIN [damage-runs=60] [seed]

STEP_ONLY=s_import,s_damaged ... runs some sections; BEE_CPU (default 10)
pins the timed runs; STEP_REAL=dir names real-world files; STEP_REL a release
build to time.
"""
import os, random, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401  (HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
ONLY = [s for s in os.environ.get('STEP_ONLY', '').split(',') if s]
QUICK = os.environ.get('STEP_QUICK') == '1'  # (the mutants: fewer fixtures)
REAL = os.environ.get('STEP_REAL', os.path.join(ROOT, '../.step-real'))
FAILS = []
# (headless, the port writes only under /tmp)
T = tempfile.mkdtemp(prefix='beestep-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
QUERIES = ['volume', 'area', 'faces', 'edges', 'vertices', 'loops', 'valid', 'triangles', 'tessvolume', 'watertight',
           'planes', 'cylinders', 'cones', 'spheres', 'tori', 'nurbs']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bs_run(code, timeout=900):
    """BeeModel runs a BeeScript: (exit code, its printed lines)."""
    p = os.path.join(T, 's.bees')
    open(p, 'w').write(code)
    r = subprocess.run([BIN, '--run', p], env=ENV, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.splitlines()


def port(*a, binary=None, timeout=900, log=None):
    lg = log or os.path.join(T, 'log.txt')
    r = subprocess.run([binary or BIN, '--shot', os.path.join(T, 'u.ppm'), '--dump-log', lg, *a],
                       env=ENV, capture_output=True, text=True, timeout=timeout)
    return r


def said(lg):
    """The console lines for the STEP commands (their first words)."""
    out = []
    for ln in open(lg, errors='replace').read().splitlines():
        for w in ('  imported ', '  no solids in ', '  could not read ', '  exported ', '  no B-rep solids to export', '  could not write '):
            if ln.startswith(w):
                out.append(w.strip())
    return out


# ---- fixtures: BeeModel's features exported ---------------------------------------

SOLIDS = '''
s = sketch("SBox", "XY")
rect(s, 0, 0, 2, 1)
pad("Box", s, 0.5)
c = sketch("SCyl", "XZ")
circle(c, 10, 0, 1)
pad("Cyl", c, 2)
k = sketch("SCone", "XY")
p0 = point(k, 0, 0)
p1 = point(k, 1, 0)
p2 = point(k, 0, 2)
line(k, p0, p1)
line(k, p1, p2)
line(k, p2, p0)
revolve("Cone", k, 2*P, "v")
t = sketch("STor", "XY")
circle(t, 3, 0, 1)
revolve("Torus", t, 2*P, "v")
q = sketch("SPart", "XY")
circle(q, 3, 0, 1)
revolve("Quarter", q, P/2, "v")
g = sketch("SRing", "XY")
rect(g, -2, -1, 4, 2)
circle(g, 0, 0, 0.5)
pad("Plate", g, 0.3)
hb = sketch("SBall2", "XY")
arc(hb, 0, 0, 1, -P/2, P/2)
line(hb, 0, 1, 0, -1)
revolve("Ball", hb, 2*P, "v")
'''

BOOLS = '''
s = sketch("S1", "XY")
rect(s, 0, 0, 4, 2)
pad("Box", s, 1)
k = sketch("Cut", "XY", 1)
rect(k, 1, 0.5, 2, 1)
pocket("Box", k, 0.4)
s2 = sketch("S2", "XY")
rect(s2, 10, 0, 4, 2)
pad("Plate", s2, 0.5)
h = sketch("Drill", "XY", 0.5)
point(h, 12, 1)
hole("Plate", h, 1)
s3 = sketch("S3", "XY")
rect(s3, 20, 0, 4, 2)
pad("Step", s3, 1)
t = sketch("Top", "XY", 1)
rect(t, 21, 0.5, 1, 1)
pad("Step", t, 0.5)
c = sketch("RodS", "XY")
circle(c, 30, 0, 1)
pad("Rod", c, 4)
x = sketch("Cross", "XZ", 0)
point(x, 30, -2)
hole("Rod", x, 0.6)
s4 = sketch("S4", "XY")
rect(s4, 40, -2, 4, 4)
pad("Holes", s4, 0.5)
hs = sketch("Hs", "XY", 0.5)
point(hs, 41, -1)
point(hs, 43, -1)
point(hs, 41, 1)
point(hs, 43, 1)
hole("Holes", hs, 0.5)
b = sketch("S5", "XY")
rect(b, 50, 0, 3, 2)
pd = pad("Cup", b, 2)
shell("Cup", pd, 0.2)
f = sketch("BoxS", "XZ")
rect(f, 60, 0, 4, 2)
pad("Fil", f, 1)
fillet("Fil", 0.3, "vertical")
g = sketch("BoxT", "XZ")
rect(g, 70, 0, 4, 2)
pad("Cham", g, 1)
chamfer("Cham", 0.2, "vertical")
set("Fil", "color", 16711680)
set("Cham", "color", 3368652)
'''

# one solid, moved, turned and coloured (written in place); its name has a quote
ALONE = '''
s = sketch("SA", "XY")
rect(s, 0, 0, 2, 1)
circle(s, 1, 0.5, 0.3)
pad("Bob's", s, 0.7)
set("Bob's", "x", 1.5)
set("Bob's", "y", -2)
set("Bob's", "rz", 0.7)
set("Bob's", "rx", 0.3)
set("Bob's", "color", 1193046)
'''

# two turned parts: an assembly placed by their transforms
ASSY = '''
c = sketch("SC", "XZ")
circle(c, 0, 0, 1)
pad("Shaft", c, 3)
t = sketch("ST", "XY")
circle(t, 3, 0, 0.5)
revolve("Ring", t, 2*P, "v")
set("Ring", "rx", 1.2)
set("Ring", "z", 0.5)
set("Shaft", "ry", -0.4)
set("Shaft", "x", 2)
'''

FIXTURES = [('solids', SOLIDS, 'm'), ('bools_m', BOOLS, 'm'), ('bools_mm', BOOLS, 'mm'), ('bools_cm', BOOLS, 'cm'),
            ('bools_in', BOOLS, 'in'), ('alone', ALONE, 'm'), ('alone_in', ALONE, 'in'), ('assy', ASSY, 'mm')]


UNIT = {'m': 1.0, 'cm': 0.01, 'mm': 0.001, 'in': 0.0254}
POWER = {'volume': 3, 'tessvolume': 3, 'area': 2}


def solids_code(path_bee):
    """BeeScript: the scene saved, then each kernel solid's name and brep() values printed."""
    code = f'op("file.save", "{path_bee}")\n'
    code += 'for i in 0..count() {\n n = name(i)\n if brep(n, "kernel") == 1 {\n  print("N", n)\n'
    # (print takes at most 16 arguments)
    code += '  print("Q", ' + ', '.join(f'brep(n, "{q}")' for q in QUERIES[:8]) + ')\n'
    code += '  print("R", ' + ', '.join(f'brep(n, "{q}")' for q in QUERIES[8:]) + ')\n }\n}\n'
    return code


def parse_q(lines):
    qo, cur = {}, None
    for ln in lines:
        if ln.startswith('N '):
            cur = ln[2:]
        elif ln.startswith('Q ') and cur is not None:
            qo[cur] = ln.split()[1:]
        elif ln.startswith('R ') and cur is not None:
            qo[cur] += ln.split()[1:]
    return qo


def make_fixture(name, body, unit):
    """BeeModel builds the features and exports them: (step, unit, the saved scene, {solid: printed brep()})."""
    p = os.path.join(T, name + '.step')
    sb = os.path.join(T, name + '.bee')
    rc, lines = bs_run(f'op("cad.kernel", "on")\ndelete("Cube")\nop("scene.units", "{unit}")\nP = 3.14159265358979\n' + body +
                       solids_code(sb) + f'op("file.export_step", "{p}")\n')
    qs = parse_q(lines)
    check(rc == 0 and os.path.exists(p) and os.path.exists(sb) and qs,
          f'fixture {name}: made, {len(qs)} solids, exported (rc {rc})')
    return (p, unit, sb, qs) if os.path.exists(p) and os.path.exists(sb) else None


def make_fixtures():
    out = {}
    for name, body, unit in FIXTURES:
        if QUICK and name not in ('solids', 'bools_m', 'alone', 'assy', 'bools_in'):
            continue
        fx = make_fixture(name, body, unit)
        if fx:
            out[name] = fx
    return out


def plain(n):
    """A name as it comes back from a STEP file (no quotes)."""
    return n.replace("'", '')


_NUM = re.compile(rb'[-+]?\d+\.\d*(?:E[-+]?\d+)?')


def step_same(a, b, *names):
    """Two STEP files the same: the text the same but the file name (and quotes
    doubled in names), the reals to 1e-7 (a direction normalised again, or turned into place, may move
    in its last bits)."""
    def split(x):
        for n in names:
            x = x.replace(n.encode(), b'')
        x = x.replace(b"''", b'')
        return _NUM.sub(b'#', x), [float(m) for m in _NUM.findall(x)]
    ta, na = split(a)
    tb, nb = split(b)
    return len(a) > 1000 and ta == tb and len(na) == len(nb) and all(abs(x - y) <= 1e-7 * max(1.0, abs(x)) for x, y in zip(na, nb))


def kind_of(text):
    for w in ('no solids in', 'could not read', 'imported'):
        if text and w in text:
            return w
    return None


# ---- B-spline variants of a file: every plane a B-spline surface, every line
# a B-spline curve (plain or the rational complex entity, uniform weights so
# the geometry stays): the readers' and writers' B-spline paths on the same
# solids. (The patches reach 80 units from each plane's origin: every fixture, out to x = 74, inside.)

def _ents(txt):
    return {int(m.group(1)): m.group(2) for m in re.finditer(r'#(\d+)=(.*?);\r?\n', txt)}


def _nums(s):
    return [float(x) for x in re.findall(r'[-+]?\d+\.\d*(?:E[-+]?\d+)?|[-+]?\d+\.?(?:E[-+]?\d+)?', s)]


def _real(x):
    return repr(float(x)).upper().replace('E+', 'E')


def nurbs_variant(txt, rational=False, deg=2, big=80.0):
    e = _ents(txt)
    nid = [max(e) + 1]

    def new(body):
        k = nid[0]
        nid[0] += 1
        extra.append(f'#{k}={body};')
        return k

    def point(p):
        return new("CARTESIAN_POINT('',(" + ','.join(_real(c) for c in p) + '))')

    def vec(ref):
        return _nums(e[ref].split('(', 2)[2])[:3]

    extra = []
    out = []
    for k in sorted(e):
        body = e[k]
        if body.startswith('PLANE('):
            ax = int(re.findall(r'#(\d+)', body)[0])
            refs = [int(x) for x in re.findall(r'#(\d+)', e[ax])]
            o = vec(refs[0])
            z = vec(refs[1]) if len(refs) > 1 else [0, 0, 1]
            x = vec(refs[2]) if len(refs) > 2 else [1, 0, 0]
            y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]]
            n = deg + 1
            rows = []
            for i in range(n):
                row = []
                for j in range(n):
                    u = -big + 2 * big * i / deg
                    v = -big + 2 * big * j / deg
                    row.append(point([o[c] + u * x[c] + v * y[c] for c in range(3)]))
                rows.append('(' + ','.join(f'#{r}' for r in row) + ')')
            pts = '(' + ','.join(rows) + ')'
            km = f'({n},{n})'
            kk = '(0.,1.)'
            if rational:
                w = '(' + ','.join('(' + ','.join(['1.5'] * n) + ')' for _ in range(n)) + ')'
                body = (f'(BOUNDED_SURFACE() B_SPLINE_SURFACE({deg},{deg},{pts},.UNSPECIFIED.,.F.,.F.,.F.) '
                        f'B_SPLINE_SURFACE_WITH_KNOTS({km},{km},{kk},{kk},.UNSPECIFIED.) GEOMETRIC_REPRESENTATION_ITEM() '
                        f'RATIONAL_B_SPLINE_SURFACE({w}) REPRESENTATION_ITEM(\'\') SURFACE())')
            else:
                body = f"B_SPLINE_SURFACE_WITH_KNOTS('',{deg},{deg},{pts},.UNSPECIFIED.,.F.,.F.,.F.,{km},{km},{kk},{kk},.UNSPECIFIED.)"
        elif body.startswith('EDGE_CURVE('):
            refs = [int(x) for x in re.findall(r'#(\d+)', body)]
            cur = e[refs[2]]
            if cur.startswith('LINE('):
                pa = int(re.findall(r'#(\d+)', e[refs[0]])[0])
                pb = int(re.findall(r'#(\d+)', e[refs[1]])[0])
                if rational:
                    c = new(f"(BOUNDED_CURVE() B_SPLINE_CURVE(1,(#{pa},#{pb}),.UNSPECIFIED.,.F.,.F.) B_SPLINE_CURVE_WITH_KNOTS((2,2),(0.,1.),"
                            f".UNSPECIFIED.) CURVE() GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_CURVE((2.,2.)) REPRESENTATION_ITEM(''))")
                else:
                    c = new(f"B_SPLINE_CURVE_WITH_KNOTS('',1,(#{pa},#{pb}),.UNSPECIFIED.,.F.,.F.,(2,2),(0.,1.),.UNSPECIFIED.)")
                body = body.replace(f'#{refs[2]},', f'#{c},', 1)
        out.append(f'#{k}={body};')
    head = txt[:txt.index('DATA;') + 5]
    return head + '\n' + '\n'.join(out + extra) + '\nENDSEC;\nEND-ISO-10303-21;\n'


def obj_rows(path):
    """The mesh objects of a .bee: their record and their mesh."""
    oa = beefile.objects(path)
    ma = beefile.meshes(path)
    return [(o, ma[o['mesh']]) for o in oa if o['type'] == 0]


def close(a, b, tol):
    return abs(a - b) <= tol * max(1.0, abs(b))


def printed_close(ov, pv, scale):
    """A brep() value as BeeScript printed it (6 decimals, or 7 digits with an
    exponent), scaled, against the full value: within half its last digit."""
    if ov == 'nil' or pv == 'nil':
        return ov == pv
    a = float(ov)
    unit = abs(a) * 1e-6 if 'e' in ov else max(abs(a) * 1e-6, 1e-6)
    return abs(a * scale - float(pv)) <= 0.5 * unit * scale + 1e-12 * abs(a * scale)


def same_mesh(ma, mb, f=1.0):
    """The same vertices and as many polygons (a quad's diagonal may flip with a
    direction's last bit)."""
    return len(ma[1]) == len(mb[1]) and len(ma[0]) == len(mb[0]) and all(
        close(x * f, y, 1e-5) for p, q in zip(ma[0], mb[0]) for x, y in zip(p, q))


def dumps(d, tag, names):
    out = {}
    for k, n in enumerate(names):
        try:
            out[n] = dict(ln.split() for ln in open(f'{d}/{tag}{k}.txt'))
        except OSError:
            out[n] = {}
    return out


def check_import(fx, units, tag, queries=True, exact=True, colour=None):
    """BeeModel imports the fixture into a scene in these units: each solid with
    its place, turn and colour as made and its brep() as made (scaled by the
    units); a sane mesh; exported and imported again, the same file, meshes and
    brep(). exact=False (B-spline variants): the surface kinds may differ, the
    volumes and topology may not."""
    step, unit, src_bee, qs = fx
    f = UNIT[unit] / UNIT[units]
    d = tempfile.mkdtemp(dir=T)
    names = list(qs)
    runs = []
    for i, (src, out) in enumerate(((step, 'x'), (f'{d}/x.step', 'y'))):
        args = ['--op', f'scene.units {units}', '--op', f'file.import_step {src}', '--op', f'file.save_as {d}/{out}.bee',
                '--op', f'file.export_step {d}/{out}.step']
        if queries:
            for k, n in enumerate(names):
                args += ['--dump-brep', f'{d}/{out}{k}.txt;{plain(n)}']
        t0 = time.time()
        r = port(*args, log=os.path.join(d, 'log.txt'))
        runs.append((r.returncode, said(os.path.join(d, 'log.txt')), time.time() - t0))
        if r.returncode:
            check(False, f'{tag}: BeeModel stopped ({r.returncode}) {r.stderr[-300:]}')
            return
    check(all(s_[:1] == ['imported'] and 'exported' in s_ for _, s_, _ in runs), f'{tag}: imported and exported, twice ({runs[0][1]})')
    src = {plain(o['name']): (o, m) for o, m in obj_rows(src_bee)}
    got = {o['name']: (o, m) for o, m in obj_rows(d + '/x.bee')}
    again = {o['name']: (o, m) for o, m in obj_rows(d + '/y.bee')}
    # (one solid alone is written in place: its turn and move are in its geometry)
    alone = len(names) == 1
    bad, nv = [], 0
    for n in names:
        if plain(n) not in got or plain(n) not in src or plain(n) not in again:
            bad.append(f'{n} missing')
            continue
        (a, ma), (b, mb), (c, mc) = src[plain(n)], got[plain(n)], again[plain(n)]
        diff = []
        if not alone and not all(close(x * f, y, 1e-5) for x, y in zip(a['loc'], b['loc'])):
            diff.append(f"loc {b['loc']}")
        if not alone and not all(close(x, y, 1e-5) for x, y in zip(a['rot'], b['rot'])):
            diff.append(f"rot {b['rot']}")
        if b['color'] != (a['color'] if colour is None else colour):
            diff.append(f"colour {b['color']:06x}")
        if not mb[1] or not finite([x for v in mb[0] for x in v]) or max(i for q in mb[1] for i in q) >= len(mb[0]):
            diff.append('mesh not sane')
        if not same_mesh(mb, mc) or b['loc'] != c['loc'] or b['rot'] != c['rot'] or b['color'] != c['color']:
            diff.append('not the same imported again')
        if diff:
            bad.append(f'{n}: {" ".join(diff)}')
        nv += len(mb[0])
    check(not bad and nv > 0 and len(names) > 0,
          f'{tag}: {len(names)} solids, {nv} vertices: {"" if alone else "places, turns, "}colours as made (scaled x{f:g}), sane meshes, the same imported again {bad[:3]}')
    x = open(d + '/x.step', 'rb').read() if os.path.exists(d + '/x.step') else b''
    y = open(d + '/y.step', 'rb').read() if os.path.exists(d + '/y.step') else b''
    check(step_same(x, y, 'x.step', 'y.step'), f'{tag}: export -> import -> export, the same {len(x)} bytes')
    if exact and units == unit:
        check(step_same(x, open(step, 'rb').read(), 'x.step', os.path.basename(step)), f'{tag}: exported again in its own units, the same file as made')
    if queries and names:
        q1, q2 = dumps(d, 'x', names), dumps(d, 'y', names)
        off, tess = [], []
        for n in names:
            pv = q1[n]
            if not pv:
                off.append(f'{n}: no dump')
                continue
            for q, ov in zip(QUERIES, qs[n]):
                if q in ('triangles', 'tessvolume') or (not exact and q in ('planes', 'cylinders', 'cones', 'spheres', 'tori', 'nurbs')):
                    continue
                v = pv.get(q, 'nil')
                ok = printed_close(ov, v, f ** POWER.get(q, 0)) if exact else (
                    ov == v == 'nil' or (ov != 'nil' and v != 'nil' and close(float(ov) * f ** POWER.get(q, 0), float(v), 1e-4)))
                if not ok:
                    off.append(f'{n} {q} {ov} -> {v}')
            try:
                vol, tv, tri = float(pv['volume']), float(pv['tessvolume']), float(pv['triangles'])
                if not (tri > 0 and abs(tv - vol) <= 0.02 * abs(vol)):
                    tess.append(f'{n}: volume {vol:g} tessellated {tv:g}, {tri:g} triangles')
            except (KeyError, ValueError):
                tess.append(f'{n}: no values')
            if any(not close(float(pv[q]), float(q2[n].get(q, 'nan')), 1e-6) for q in QUERIES if pv.get(q, 'nil') != 'nil'):
                tess.append(f'{n}: imported again, other values')
        check(not off, f'{tag}: brep() of {len(names)} solids: volume, area, topology{", surface kinds" if exact else ""} as made (scaled x{f:g}) {off[:4]}')
        check(not tess, f'{tag}: the tessellations within 2% of the volumes, the same imported again {tess[:3]}')
    print(f'       (times {runs[0][2]:.1f} s, {runs[1][2]:.1f} s)')


def finite(v):
    return all(c == c and abs(c) != float('inf') for c in v)


def s_import():
    print('-- import: BeeModel\'s exports, three scene units --')
    fx = make_fixtures()
    check(len(fx) == (5 if QUICK else len(FIXTURES)), f'{len(fx)} fixtures made')
    for name, f in fx.items():
        for units in ('m', 'mm', 'in') if name in ('solids', 'bools_m', 'assy', 'alone') and not QUICK else (f[1],):
            check_import(f, units, f'{name} into {units}')
    # B-spline surfaces and curves (plain, rational) in place of planes and lines
    for nm, kw in (('nurbs', {}), ('rational', {'rational': True}), ('nurbs deg 1', {'deg': 1})):
        for src_name in ('bools_m', 'solids') if not QUICK else ('solids',):
            if src_name not in fx:
                continue
            vp = os.path.join(T, f'{src_name}_{nm.replace(" ", "_")}.step')
            open(vp, 'w').write(nurbs_variant(open(fx[src_name][0]).read(), **kw))
            check_import((vp,) + fx[src_name][1:], 'm', f'{src_name} as B-splines ({nm})', exact=False)
    # one placed solid alone written in place (the assembly's other part deleted)
    if 'assy' in fx:
        d = tempfile.mkdtemp(dir=T)
        port('--op', f'file.import_step {fx["assy"][0]}', '--select', 'Shaft', '--op', 'object.delete', '--op', f'file.export_step {d}/p.step',
             '--dump-brep', f'{d}/a.txt;Ring')
        b = open(f'{d}/p.step', 'rb').read() if os.path.exists(f'{d}/p.step') else b''
        port('--op', f'file.import_step {d}/p.step', '--op', f'file.save_as {d}/q.bee', '--dump-brep', f'{d}/b.txt;Ring')
        rb = {o['name']: o for o, m in obj_rows(f'{d}/q.bee')} if os.path.exists(f'{d}/q.bee') else {}
        qa = dict(ln.split() for ln in open(f'{d}/a.txt')) if os.path.exists(f'{d}/a.txt') else {}
        qb = dict(ln.split() for ln in open(f'{d}/b.txt')) if os.path.exists(f'{d}/b.txt') else {}
        same = all(q in qa and q in qb and qa[q] != 'nil' and close(float(qa[q]), float(qb[q]), 1e-6) for q in ('volume', 'area', 'faces', 'edges'))
        check(len(b) > 1000 and b'Assembly' not in b and 'Shaft' not in rb and 'Ring' in rb and same,
              f'one turned solid alone: written in place ({len(b)} bytes), read back with the same volume, area and topology')
    # variants of the text: CRLF, comments, blanks, colours from other systems
    # (reals that round, not truncate, to bytes): the same bodies
    if 'bools_m' in fx:
        src = open(fx['bools_m'][0], 'rb').read()
        var = re.sub(rb"COLOUR_RGB\('',[^)]*\)", b"COLOUR_RGB('',0.7,0.29,0.584)", src)
        var = var.replace(b';\n', b';\r\n/* a comment */\r\n').replace(b',', b' , ')
        vp = os.path.join(T, 'variant.stp')
        open(vp, 'wb').write(var)
        check_import((vp,) + fx['bools_m'][1:], 'm', 'bools with CRLF, comments, blanks (.stp)', queries=False, exact=False,
                     colour=(round(0.7 * 255) << 16) | (round(0.29 * 255) << 8) | round(0.584 * 255))


def s_real():
    print('-- real-world files --')
    if not os.path.isdir(REAL):
        print(f'  skip (no folder {REAL}: STEP_REAL=dir)')
        return
    fs = sorted(f for f in os.listdir(REAL) if f.lower().endswith(('.stp', '.step')))
    fs = [f for f in fs if os.path.getsize(os.path.join(REAL, f)) < int(os.environ.get('STEP_REAL_MAX', 3000000))]
    for f in fs:
        d = tempfile.mkdtemp(dir=T)
        lg = os.path.join(d, 'log.txt')
        r = port('--op', f'file.import_step {os.path.join(REAL, f)}', '--op', f'file.save_as {d}/p.bee', '--op', f'file.export_step {d}/x.step', log=lg)
        s_ = said(lg)
        rows = obj_rows(f'{d}/p.bee') if os.path.exists(f'{d}/p.bee') else []
        sane = all(finite([c for v in m[0] for c in v]) for _, m in rows)
        check(r.returncode == 0 and s_[:1] == ['imported'] and len(rows) > 1 and sane, f'real: {f}: imported, {len(rows) - 1} objects, finite meshes ({s_})')
        port('--op', f'file.import_step {d}/x.step', '--op', f'file.export_step {d}/y.step', log=lg)
        x = open(f'{d}/x.step', 'rb').read() if os.path.exists(f'{d}/x.step') else b''
        y = open(f'{d}/y.step', 'rb').read() if os.path.exists(f'{d}/y.step') else b''
        check(step_same(x, y, 'x.step', 'y.step'), f'real: {f}: export -> import -> export, the same {len(x)} bytes')


# ---- damaged input -------------------------------------------------------------------------

def damaged_cases(rng, base):
    cases = {}
    for k in range(RUNS // 4):
        cases[f'trunc{k}'] = base[:rng.randrange(len(base))]
    for k in range(RUNS // 4):
        b = bytearray(base)
        for _ in range(rng.randrange(1, 40)):
            b[rng.randrange(len(b))] = rng.randrange(256)
        cases[f'flip{k}'] = bytes(b)
    for k in range(RUNS // 4):
        b = bytearray(base)
        i, j = rng.randrange(len(b)), rng.randrange(len(b))
        b[i:i] = base[j:j + rng.randrange(2000)]
        cases[f'splice{k}'] = bytes(b)
    for k in range(RUNS // 4):
        # numbers replaced: zero, huge, NaN-making, negative
        txt = base
        for _ in range(rng.randrange(1, 6)):
            nums = list(re.finditer(rb'-?\d\.\d+E[+-]\d\d', txt))
            if not nums:
                break
            m = rng.choice(nums)
            txt = txt[:m.start()] + rng.choice([b'0.', b'1.E999', b'-1.E999', b'1.E-320', b'-0.', b'123456789.', b'1']) + txt[m.end():]
        cases[f'num{k}'] = txt
    hdr = b"ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n"
    face = (b"#3=CARTESIAN_POINT('',(0.,0.,0.));\n#4=VERTEX_POINT('',#3);\n#5=EDGE_CURVE('',#4,#4,#2,.T.);\n"
            b"#6=ORIENTED_EDGE('',*,*,#5,.T.);\n#7=EDGE_LOOP('',(#6));\n#8=FACE_OUTER_BOUND('',#7,.T.);\n#9=PLANE('',#10);\n"
            b"#10=AXIS2_PLACEMENT_3D('',#3,$,$);\n#11=ADVANCED_FACE('',(#8),#9,.T.);\n#12=CLOSED_SHELL('',(#11));\n"
            b"#13=MANIFOLD_SOLID_BREP('',#12);\nENDSEC;\n")
    cases.update({
        'deep_nesting': hdr + b"#1=MANIFOLD_SOLID_BREP('',#2);\n#2=CLOSED_SHELL('',(" + b"(" * 200000 + b")" * 200000 + b"));\nENDSEC;\n",
        'deep_open': hdr + b"#1=X(" + b"(" * 300000,
        'huge_ids': hdr + b"#4294967295=CARTESIAN_POINT('',(0.,0.,0.));\n#99999999999=VERTEX_POINT('',#4294967295);\nENDSEC;\n",
        'huge_id_solid': hdr + b"#2000000000=MANIFOLD_SOLID_BREP('',#1);\n#1=CLOSED_SHELL('',(#2000000000));\nENDSEC;\n",
        'cycle_vector': hdr + b"#1=VECTOR('',#1,1.);\n#2=LINE('',#3,#1);\n" + face,
        'cycle_curve': hdr + b"#2=SURFACE_CURVE('',#2,(),.CURVE_3D.);\n" + face,
        'cycle_unit': base.replace(b"SI_UNIT($,.METRE.));", b"CONVERSION_BASED_UNIT('X',#900002));\n#900002=LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(2.),#5);", 1),
        'huge_degree': hdr + b"#2=B_SPLINE_CURVE_WITH_KNOTS('',1000,(#3,#3,#3),.UNSPECIFIED.,.F.,.F.,(1004),(0.),.UNSPECIFIED.);\n" + face,
        'negative_degree': hdr + b"#2=B_SPLINE_CURVE_WITH_KNOTS('',-5,(#3,#3,#3),.UNSPECIFIED.,.F.,.F.,(4),(0.),.UNSPECIFIED.);\n" + face,
        'huge_list': hdr + b"#1=CLOSED_SHELL('',(" + b",".join(b"#2" for _ in range(300000)) + b"));\n#3=MANIFOLD_SOLID_BREP('',#1);\nENDSEC;\n",
        'many_entities': hdr + b"".join(b"#%d=CARTESIAN_POINT('',(1.,2.,3.));\n" % i for i in range(1, 200000)),
        'empty': b'',
        'no_data': b"ISO-10303-21;\nHEADER;\nENDSEC;\n",
        'binary': bytes(rng.randrange(256) for _ in range(5000)),
        'data_only': b"DATA;",
        'open_string': hdr + b"#1=PRODUCT('abc",
        'open_comment': hdr + b"#1=PRODUCT('abc');/*",
        'nan_reals': base.replace(b"2.0000000000000000E+00", b"1.E999").replace(b"5.0000000000000000E-01", b"-1E99999"),
    })
    return cases


def s_damaged():
    print(f'-- damaged and garbage STEP (seed {SEED}) --')
    rng = random.Random(SEED)
    base_p = os.path.join(T, 'dmg_base.step')
    bs_run('op("cad.kernel", "on")\ndelete("Cube")\nP = 3.14159265358979\n' + SOLIDS + f'op("file.export_step", "{base_p}")\n')
    base = open(base_p, 'rb').read() if os.path.exists(base_p) else b''
    check(len(base) > 1000, f'the base file made ({len(base)} bytes)')
    if not base:
        return
    cases = damaged_cases(rng, base)
    dd = os.path.join(T, 'dmg')
    os.makedirs(dd, exist_ok=True)
    crashes, slow, mute, kinds = [], [], [], {}
    for n, data in sorted(cases.items()):
        p = os.path.join(dd, n + '.step')
        open(p, 'wb').write(data)
        t0 = time.time()
        try:
            r = port('--op', f'file.import_step {p}', '--op', f'file.export_step {dd}/re.step', timeout=180)
            if r.returncode:
                crashes.append(f'{n} rc {r.returncode}')
            s_ = said(os.path.join(T, 'log.txt'))
            k = kind_of(' '.join(s_[:1]))
            kinds[k] = kinds.get(k, 0) + 1
            # one verdict on the file; the export after it says something too
            if k is None or len(s_) != 2 or s_[1] not in ('exported', 'no B-rep solids to export', 'could not write'):
                mute.append(f'{n}: {s_}')
        except subprocess.TimeoutExpired:
            crashes.append(f'{n} hung')
        if time.time() - t0 > 60:
            slow.append(n)
    check(not crashes, f'{len(cases)} damaged files: BeeModel never crashes or hangs {crashes[:5]}')
    check(not slow, f'... each within a minute {slow}')
    check(not mute, f'... each: "imported", "no solids in" or "could not read", then the export answers ({kinds}) {mute[:4]}')


# ---- undo, files --------------------------------------------------------------------------

def s_undo():
    print('-- undo and files --')
    p = os.path.join(T, 'u.step')
    bs_run('op("cad.kernel", "on")\ndelete("Cube")\nP = 3.14159265358979\n' + ASSY + f'op("file.export_step", "{p}")\n')
    lg = os.path.join(T, 'ulog.txt')
    r = port('--op', f'file.import_step {p}', '--op', f'file.export_step {T}/u0.step', '--key', 'ctrl+z', '--op', f'file.export_step {T}/u1.step',
             '--key', 'ctrl+shift+z', '--op', f'file.export_step {T}/u2.step', '--op', f'file.save_as {T}/u.bee',
             '--op', f'file.open {T}/u.bee', '--op', f'file.export_step {T}/u3.step', log=lg)
    s = said(lg)
    a = open(f'{T}/u0.step', 'rb').read() if os.path.exists(f'{T}/u0.step') else b''
    b = open(f'{T}/u2.step', 'rb').read() if os.path.exists(f'{T}/u2.step') else b''
    a, b = a.replace(b'u0.step', b''), b.replace(b'u2.step', b'')
    check(r.returncode == 0 and s == ['imported', 'exported', 'no B-rep solids to export', 'exported', 'no B-rep solids to export'] and a == b and len(a) > 1000,
          f'import, export; undone: nothing to export; redone: the same file; saved and reopened: no B-rep ({s})')
    # the solids follow the objects themselves: none after file.open
    r = port('--op', f'file.import_step {p}', '--op', f'file.save_as {T}/u6.bee', '--op', f'file.open {T}/u.bee',
             '--op', f'file.export_step {T}/u5.step', log=lg)
    check(said(lg) == ['imported', 'no B-rep solids to export'] and 'Opened u.bee' in open(lg).read(),
          f'another file opened: nothing to export ({said(lg)})')
    # deleting the objects: their solids no longer exported
    r = port('--op', f'file.import_step {p}', '--op', 'object.select_all', '--op', 'object.select_all', '--op', 'object.delete',
             '--op', f'file.export_step {T}/u4.step', log=lg)
    check(said(lg) == ['imported', 'no B-rep solids to export'], f'objects deleted: nothing to export ({said(lg)})')
    # more than 16 imports in a session: 16 files' texts are kept
    args = []
    for k in range(17):
        args += ['--op', f'file.import_step {p}']
    port(*args, log=lg)
    s = said(lg)
    check(s == ['imported'] * 16 + ['could not read'], f'the 17th file in a session cannot be kept: "could not read" ({s[-2:]})')


# ---- the window -----------------------------------------------------------------------------

def s_window():
    print('-- menus, the file browser, drops --')
    ui = os.path.join(T, 'ui.txt')
    port('--click-label', 'File', '--click-label', 'Import', '--dump-ui', ui)
    txt = open(ui).read() if os.path.exists(ui) else ''
    imp = [ln for ln in txt.splitlines() if 'Import STEP' in ln]
    check(imp and 'off' not in imp[0].split('\t')[-1:], f'File > Import lists "Import STEP..." and it can run ({imp[:1]})')
    port('--click-label', 'File', '--click-label', 'Export', '--dump-ui', ui)
    txt = open(ui).read() if os.path.exists(ui) else ''
    check(any('Export STEP' in ln for ln in txt.splitlines()), 'File > Export lists "Export STEP..."')
    # the browser: .step and .stp, nothing else (headless, its home is
    # /tmp/beemodel-headless: names of our own there, removed after)
    d = '/tmp/beemodel-headless/BeeModel'
    os.makedirs(d, exist_ok=True)
    tag = f'zzstep{os.getpid()}'
    names = [f'{tag}a.step', f'{tag}b.STP', f'{tag}c.txt', f'{tag}d.stl']
    for f in names:
        open(os.path.join(d, f), 'w').write('x')
    try:
        port('--click-label', 'File', '--click-label', 'Import', '--click-label', 'Import STEP...', '--dump-ui', ui)
        txt = open(ui).read() if os.path.exists(ui) else ''
    finally:
        for f in names:
            os.remove(os.path.join(d, f))
    seen = [f for f in names if f'file\t{f}' in txt or f'row\t{f}' in txt]   # (Zui's browser: its rows)
    check(seen == names[:2], f'the file browser lists the .step and .stp files only ({[x[len(tag):] for x in seen]})')
    # a dropped .step imports (drop.s: the kinds it opens)
    sys.path.insert(0, HERE)
    src = open(os.path.join(ROOT, 'src', 'drop.zig')).read()
    check('return .step' in src and 'file.import_step' in src, 'dropped .step / .stp files go to file.import_step')


# ---- timings -------------------------------------------------------------------------------

def s_speed():
    print('-- timings (one CPU) --')
    rel = os.environ.get('STEP_REL')  # a release build
    if not rel:
        print('  skip (STEP_REL=<release binary>)')
        return
    p = os.path.join(T, 'speed.step')
    bs_run('op("cad.kernel", "on")\ndelete("Cube")\nP = 3.14159265358979\n' + BOOLS + f'op("file.export_step", "{p}")\n')
    files = [p] + ([os.path.join(REAL, f) for f in sorted(os.listdir(REAL)) if f.endswith(('.stp', '.step'))] if os.path.isdir(REAL) else [])
    for f in files:
        t0 = time.time()
        r = subprocess.run(['taskset', '-c', CPU, rel, '--shot', T + '/u.ppm', '--op', f'file.import_step {f}', '--op', f'file.export_step {T}/sp.step'],
                           env=ENV, capture_output=True, timeout=3600)
        tp = time.time() - t0
        check(r.returncode == 0, f'{os.path.basename(f)}: the release build runs it cleanly')
        print(f'       {os.path.basename(f)}: {tp:.2f} s (import, tessellate, export)')


def main():
    print(f'STEP ({BIN}, damage runs {RUNS}, seed {SEED})')
    for s in (s_import, s_real, s_damaged, s_undo, s_window, s_speed):
        if ONLY and s.__name__ not in ONLY:
            continue
        s()
    shutil.rmtree(T, True)
    print(f'step: fails {len(FAILS)}')
    for f in FAILS:
        print('  -', f)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
