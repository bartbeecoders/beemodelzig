#!/usr/bin/env python3
"""Geometry nodes (geonodes.zig), the field VM and its JIT (fieldvm.zig),
instances (inst.zig) and the Geometry Nodes modifier, standalone.

Every scene is made by the operators (tree.new, tree.node, tree.link,
tree.node_set, tree.group, object.modifier_add_geometry,
object.modifier_set) and read back through the STL export (the evaluated
mesh's triangles, every float) and the .bee chunks (NTRE, MODS).

  * s_nodes: every node type and every input / mode (the primitives,
    Transform and its instances, Join, Set Position, Extrude, Subdivision,
    Boolean, Merge by Distance, Realize, Distribute, Instance on Points, Mesh
    Line, the Math and Vector Math operations, Noise, Random, Position,
    Normal, Index, Value, Combine / Separate, groups with fields crossing in,
    nested groups, a group that runs itself, groups that run each other):
    evaluated cleanly, the triangles finite; most trees make triangles;
  * s_vm: three 1 002 001-point programs run by the JIT (AVX), its SSE path
    and the interpreter (BEEMODEL_JIT=0 / sse): the same bits all three; the
    times (GN_REL: a release build, pinned to one CPU) printed;
  * s_ntre: tree.group on several selections, every node type made by
    tree.node (and a word it does not know): saved, opened and saved again,
    the same NTRE and MODS;
  * s_fuzz: random trees (random types, values, links, groups calling each
    other): no crash, the triangles finite, the same twice;
  * s_files: a scene saved and opened again: the same triangles, the same
    NTRE and MODS saved again;
  * s_undo: the tree operators and the modifier undone and redone: each step
    the chunks and triangles of the same steps made afresh;
  * s_damaged: damaged NTRE chunks (types past the last, links to nodes not
    there and to themselves - loops -, NaN and huge values, counts past 48)
    opened: no crash, the triangles read;
  * s_particles: particles drawn as objects (an object's mesh, a ball) in
    the viewport: every tile's own, more than the striped way;
  * s_rbody: a Geometry Nodes object's instances as rigid bodies falling on a
    ground: the hash of every body at several frames the same from a script
    and from the timeline, the instances drawn where they fell, the cache
    (SIMC) the same baked both ways;
  * s_unit: the modules' zig tests (GN_SRC: the sources, default this tree);
  * s_render: instances in the path tracer: as their realized triangles;
  * s_window: the Modifiers tab (Geo Nodes, its tree by name), the viewport
    drawing the instances (every tile's own: more than the striped way, the
    splats in their colour).

    python3 tests/geonodes.py BIN [runs=20] [seed]

BEE_CPU (default 12) pins every run; GN_ONLY=s_nodes,s_vm ... runs some;
GN_REL=path/to/release/beemodel times s_vm on a release build.
"""
import os, random, re, shutil, struct, subprocess, sys, tempfile, hashlib, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401,E402 (a HOME of our own)
import beefile  # noqa: E402

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('GN_ONLY', '').split(',') if x]
REL = os.environ.get('GN_REL')
T = tempfile.mkdtemp(prefix='beegn-', dir=os.environ.get('BEEGN_TMP', '/tmp'))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(sec):
    return not ONLY or sec in ONLY


def home():
    h = tempfile.mkdtemp(dir=T)
    os.makedirs(h + '/BeeModel', exist_ok=True)
    return h


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def make(code, env=None, timeout=600):
    """BeeScript run by BeeModel (--eval): its output."""
    h = home()
    e = dict(os.environ, HOME=h, XDG_CACHE_HOME='')
    e.update(env or {})
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--eval', code], env=e, capture_output=True, text=True, timeout=timeout)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        out = 'timeout'
    shutil.rmtree(h, True)
    return out


def port(args, env=None, binary=None, timeout=600):
    """The port headless: its log."""
    h = home()
    e = dict(os.environ, HOME=h)
    e.update(env or {})
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', h + '/x.ppm', '--dump-log', h + '/l.txt', *args], env=e, capture_output=True, text=True, timeout=timeout)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = 'timeout'
    log = open(h + '/l.txt', errors='replace').read() if os.path.exists(h + '/l.txt') else ''
    shutil.rmtree(h, True)
    return log, rc


def ops_code(ops):
    return '\n'.join(f'op("{o}", "{esc(a)}")' for o, a in ops)


def ops_args(ops):
    out = []
    for o, a in ops:
        out += ['--op', f'{o} {a}'.strip()]
    return out


def finite_stl(p):
    """Every corner of the STL's triangles finite."""
    if not os.path.exists(p):
        return False
    b = open(p, 'rb').read()
    n = struct.unpack('<I', b[80:84])[0]
    return len(b) >= 84 + 50 * n and all((x >> 23) & 0xff != 0xff for i in range(n) for x in struct.unpack_from('<9I', b, 84 + 50 * i + 12))


def tris(p):
    """The STL's triangles: 36 bytes each (the corners; a NaN or infinite
    coordinate as 0: the STL writes them so, formats.zig)."""
    if not os.path.exists(p):
        return None
    b = open(p, 'rb').read()
    n = struct.unpack('<I', b[80:84])[0]
    out = []
    for i in range(n):
        t = b[84 + 50 * i + 12:84 + 50 * i + 48]
        w = struct.unpack('<9I', t)
        if any((x >> 23) & 0xff == 0xff for x in w):
            t = struct.pack('<9I', *[0 if (x >> 23) & 0xff == 0xff else x for x in w])
        out.append(t)
    return out


def stl(name, ops, env=None):
    """The operators run, the scene's STL: (tris, finite, rc)."""
    b = f'{T}/p_{name}.stl'
    if os.path.exists(b):
        os.remove(b)
    _, rc = port(ops_args(ops) + ['--op', f'file.export_stl {b}'], env)
    return tris(b), finite_stl(b), rc


MOD = [('object.modifier_add_geometry', ''), ('object.modifier_set', '0 tree 1')]


def N(t, *a):
    return [('tree.node', f'{t} {x}') for x in a]


def L(t, *a):
    return [('tree.link', f'{t} {x}') for x in a]


def S(t, *a):
    return [('tree.node_set', f'{t} {x}') for x in a]


def tree(*ops):
    return [('tree.new', 'T'), ('tree.node', 'T output')] + [x for o in ops for x in o]


# ---- s_nodes --------------------------------------------------------------------------------

def cases_nodes():
    c = {
        'grid': tree(N('T', 'grid 3 4'), L('T', '2 1 1')),
        'cube': tree(N('T', 'cube 1.5'), L('T', '2 1 1')),
        'sphere': tree(N('T', 'sphere 0.7'), L('T', '2 1 1')),
        'cylinder': tree(N('T', 'cylinder 0.5 3'), L('T', '2 1 1')),
        'transform': tree(N('T', 'sphere 0.7', 'transform 30 45 60'), L('T', '2 3 1', '3 1 1'), S('T', '3 2 1 2 3', '3 3 0.5 2 1')),
        'join': tree(N('T', 'cube 1', 'sphere 0.5', 'join', 'input'), L('T', '2 4 1', '3 4 2', '5 4 3', '4 1 1')),
        'set_position+noise': tree(N('T', 'grid 2 6', 'set_position', 'position', 'noise 2 3 0.5', 'vector_math 3'), L('T', '2 3 1', '4 6 1', '6 3 3', '3 1 1')),
        'subdivide': tree(N('T', 'cube 2', 'subdivide 2'), L('T', '2 3 1', '3 1 1')),
        'merge': tree(N('T', 'grid 2 5', 'merge 0.5'), L('T', '2 3 1', '3 1 1')),
        'boolean': tree(N('T', 'cube 2', 'sphere 1.3', 'boolean 1'), L('T', '2 4 1', '3 4 2', '4 1 1')),
        'boolean union': tree(N('T', 'cube 2', 'sphere 1.3', 'boolean 0'), L('T', '2 4 1', '3 4 2', '4 1 1')),
        'extrude+merge': tree(N('T', 'grid 2 3', 'extrude 0.4', 'merge 0'), L('T', '2 3 1', '3 4 1', '4 1 1')),
        'extrude selection': tree(N('T', 'grid 2 4', 'extrude 0.3', 'position', 'separate_xyz', 'math 8', 'merge 0'), L('T', '2 3 1', '4 5 1', '5:0 6 1', '6 3 2', '3 7 1', '7 1 1')),
        'instance random scale': tree(N('T', 'grid 4 3', 'cube 0.3', 'instance 1 0 7', 'realize', 'random 0.5 2 3'), L('T', '2 4 1', '3 4 2', '4 5 1', '5 1 1', '6 4 3')),
        'distribute aligned': tree(N('T', 'sphere 1', 'distribute 20 5 0', 'cube 0.05', 'instance 1 1 3', 'realize'), L('T', '2 3 1', '3 5 1', '4 5 2', '5 6 1', '6 1 1')),
        'distribute thinned': tree(N('T', 'grid 3 2', 'distribute 80 9 0.2', 'cube 0.05', 'instance 0 0 0', 'realize'), L('T', '2 3 1', '3 5 1', '4 5 2', '5 6 1', '6 1 1')),
        'line instanced': tree(N('T', 'line 5 0.2 0.3 0.1', 'cube 0.1', 'instance 1 0 2', 'realize'), L('T', '2 4 1', '3 4 2', '4 5 1', '5 1 1')),
        'join+transform instances': tree(N('T', 'grid 2 1', 'cube 0.2', 'instance', 'sphere 0.3', 'line 4 0.5 0 0', 'instance', 'join', 'transform 0 30 0', 'realize'),
                                         L('T', '2 4 1', '3 4 2', '6 7 1', '5 7 2', '4 8 1', '7 8 2', '8 9 1', '9 10 1', '10 1 1'), S('T', '9 2 0.5 0.2 0.1', '9 3 1 2 1')),
        'noise color': tree(N('T', 'grid 3 20', 'set_position', 'noise 1.5 4 0.6'), L('T', '2 3 1', '4:1 3 3', '3 1 1')),
        'noise fac': tree(N('T', 'grid 3 20', 'set_position', 'noise 0.7 3 0.4', 'position'), L('T', '2 3 1', '4:0 3 3', '5 4 1', '3 1 1')),
        'vector to value': tree(N('T', 'sphere 1', 'set_position', 'position', 'math 2'), L('T', '2 3 1', '4 5 1', '5 3 3', '3 1 1'), S('T', '5 2 0.3')),
        'selection': tree(N('T', 'grid 2 8', 'set_position', 'position', 'separate_xyz', 'math 8', 'value 0.25'), L('T', '2 3 1', '4 5 1', '5:0 6 1', '7 6 2', '6 3 2', '3 1 1'), S('T', '3 3 0 0.5 0')),
        'a selection between 0 and 1': tree(N('T', 'grid 2 12', 'set_position', 'random 0 1 5'), L('T', '2 3 1', '4 3 2', '3 1 1'), S('T', '3 3 0 0.3 0')),
        'random': tree(N('T', 'grid 2 8', 'set_position', 'random -0.3 0.7 9', 'combine_xyz'), L('T', '2 3 1', '4 5 2', '5 3 3', '3 1 1')),
        'input through': tree(N('T', 'input'), L('T', '2 1 1')),
        # curves (curve.zig) and generators (procgen.zig) as nodes
        'curve line to a tube': tree(N('T', 'curve_line', 'curve_to_mesh 0.2 6 1'), L('T', '2 3 1', '3 1 1'), S('T', '2 1 -1 0 0', '2 2 1 1 0.5')),
        'curve circle, a profile': tree(N('T', 'curve_circle 24 1.5', 'curve_circle 8 0.2', 'curve_to_mesh 0.1 8 0'), L('T', '2 4 1', '3 4 2', '4 1 1')),
        'resample by count': tree(N('T', 'curve_circle 7 1', 'resample 20', 'curve_to_mesh 0.1 5 1'), L('T', '2 3 1', '3 4 1', '4 1 1')),
        'resample by length': tree(N('T', 'curve_circle 9 1', 'resample 0 0.3', 'curve_to_mesh 0.05 4 1'), L('T', '2 3 1', '3 4 1', '4 1 1')),
        'trim': tree(N('T', 'curve_circle 16 1', 'trim 0.2 0.7', 'curve_to_mesh 0.1 6 1'), L('T', '2 3 1', '3 4 1', '4 1 1')),
        'fillet': tree(N('T', 'curve_circle 4 1', 'fillet 0.3 5', 'curve_to_mesh 0.1 6 1'), L('T', '2 3 1', '3 4 1', '4 1 1')),
        'curve to points, aligned': tree(N('T', 'curve_circle 12 1', 'curve_to_points 17', 'cube 0.05', 'instance 0 1 0', 'realize'), L('T', '2 3 1', '3 5 1', '4 5 2', '5 6 1', '6 1 1')),
        'l-system plant': tree(N('T', 'lsystem 0 3 0.05 0.2'), L('T', '2 1 1')),
        'l-system koch to a tube': tree(N('T', 'lsystem 3 2 0 0.1', 'curve_to_mesh 0.02 4 0'), L('T', '2 3 1', '3 1 1')),
        'terrain': tree(N('T', 'terrain 4 32 1 7'), L('T', '2 1 1'), S('T', '2 1 2 5 0.4')),
        'terrace': tree(N('T', 'terrain 4 24 1.5 3', 'terrace 5 0.2'), L('T', '2 3 1', '3 1 1')),
        'erosion': tree(N('T', 'terrain 4 24 1.5 3', 'erode 2000 0.4 5'), L('T', '2 3 1', '3 1 1')),
        'input turned': tree(N('T', 'input', 'transform 0 0 45'), L('T', '2 3 1', '3 1 1')),
        # the x87's sin and cos: huge arguments left as they are, big ones reduced its way
        'sin, cos of big numbers': tree(N('T', 'grid 2 6', 'set_position', 'position', 'separate_xyz', 'math 2', 'math 9', 'math 2', 'math 10', 'combine_xyz'),
                                        L('T', '2 3 1', '4 5 1', '5:0 6 1', '6 7 1', '5:2 8 1', '8 9 1', '7 10 1', '9 10 3', '10 3 3', '3 1 1'), S('T', '6 2 1e20', '8 2 123456.7')),
        'normals of points': tree(N('T', 'sphere 1', 'distribute 15 2 0', 'set_position', 'normal', 'cube 0.04', 'instance 1 0 5', 'realize', 'vector_math 3'),
                                  L('T', '2 3 1', '3 4 1', '5 9 1', '9 4 3', '4 7 1', '6 7 2', '7 8 1', '8 1 1'), S('T', '9 3 0.2')),
    }
    for k in range(15):
        c[f'math {k}'] = tree(N('T', 'sphere 1.3', 'set_position', 'position', 'separate_xyz', f'math {k}', 'combine_xyz'),
                             L('T', '2 3 1', '4 5 1', '5:0 6 1', '5:2 6 2', '6 7 1', '6 7 2', '7 3 3', '3 1 1'), S('T', '7 3 0.25'))
    for k in range(10):
        for o in (0, 1):
            c[f'vector_math {k}:{o}'] = tree(N('T', 'sphere 1.3', 'set_position', 'position', 'normal', f'vector_math {k}', 'index', 'math 2'),
                                             L('T', '2 3 1', '4 6 1', '5 6 2', '7 8 1', '8 6 3', f'6:{o} 3 3', '3 1 1'), S('T', '8 2 0.01'))
    G = [('tree.new', 'T'), ('tree.new', 'G'), ('tree.new', 'H')] + N('G', 'output', 'input', 'set_position', 'combine_xyz', 'math 2') + \
        L('G', '2:0 3 1', '2:1 5 1', '5 4 2', '4 3 3', '2:2 3 2', '3 1 1') + S('G', '5 2 0.4')
    outer = lambda g: N('T', 'output', 'grid 3 10', f'group {g}', 'position', 'separate_xyz', 'normal') + L('T', '2 3 1', '4 5 1', '5:0 3 2', '6 3 3', '3 1 1')
    c['group, fields in'] = G + outer(2)
    c['nested groups'] = G + N('H', 'output', 'input', 'group 2') + L('H', '2:0 3 1', '2:1 3 2', '2:2 3 3', '3 1 1') + outer(3)
    c['group, a vector in'] = [('tree.new', 'T'), ('tree.new', 'G')] + N('G', 'output', 'input', 'set_position') + L('G', '2:0 3 1', '2:2 3 3', '3 1 1') + \
        N('T', 'output', 'sphere 1', 'group 2', 'position') + L('T', '2 3 1', '4 3 3', '3 1 1')
    c['a group of itself'] = [('tree.new', 'T')] + N('T', 'output', 'grid', 'group 1') + L('T', '2 3 1', '3 1 1')
    c['groups in a ring'] = [('tree.new', 'T'), ('tree.new', 'G'), ('tree.new', 'H')] + N('G', 'output', 'input', 'group 3') + L('G', '2 3 1', '3 1 1') + \
        N('H', 'output', 'input', 'group 2', 'transform 10') + L('H', '2 3 1', '3 4 1', '4 1 1') + N('T', 'output', 'cube', 'group 2') + L('T', '2 3 1', '3 1 1')
    return {k: v + MOD for k, v in c.items()}


def s_nodes():
    print('-- every node and mode: the evaluated triangles --')
    bad, empty = [], []
    n = 0
    for name, ops in cases_nodes().items():
        b, fin, rc = stl(re.sub(r'[^a-z0-9]', '_', name), ops)
        n += 1
        if b is None or not fin or rc != 0:
            bad.append((name, None if b is None else len(b), fin, rc))
        elif not b:
            empty.append(name)
    for x in bad:
        print('      ', x)
    check(not bad, f'{n} trees: evaluated cleanly, every triangle finite ({len(bad)} not)')
    check(len(empty) * 10 <= n, f'and they make triangles ({n - len(empty)} of {n}; none: {empty[:8]})')


# ---- s_vm ---------------------------------------------------------------------------------

VM_PROGS = {
    'noise': tree(N('T', 'grid 2 1000', 'set_position', 'noise 3 4 0.5', 'vector_math 3', 'position', 'separate_xyz', 'math 2'), L('T', '2 3 1', '4:1 5 1', '6 7 1', '7:0 8 1', '8 5 3', '5 3 3', '3 1 1')),
    'arithmetic': tree(N('T', 'grid 2 1000', 'set_position', 'position', 'vector_math 4', 'vector_math 7', 'vector_math 9', 'vector_math 0', 'vector_math 2', 'math 3', 'math 13', 'vector_math 3'),
                       L('T', '2 3 1', '4 5 1', '4 5 2', '5 6 1', '6 7 1', '4 7 2', '7 8 1', '6 8 2', '8 9 1', '4 9 2', '9:1 10 1', '10 11 1', '9 12 1', '11 12 3', '12 3 3', '3 1 1')),
    'sin cos pow': tree(N('T', 'grid 2 1000', 'set_position', 'position', 'separate_xyz', 'math 9', 'math 10', 'math 4', 'combine_xyz'), L('T', '2 3 1', '4 5 1', '5:0 6 1', '5:2 7 1', '6 8 1', '7 8 2', '8 9 2', '3 1 1', '9 3 3')),
}


def s_vm():
    print('-- the field VM: the JIT, its SSE path and the interpreter, 1 002 001 points --')
    for name, ops in VM_PROGS.items():
        ops = ops + MOD
        hs, times = [], []
        for j in (None, '0', 'sse'):
            st = f'{T}/vp.stl'
            if os.path.exists(st):
                os.remove(st)
            env = {'BEEMODEL_GN_TIME': '1'}
            if j is not None:
                env['BEEMODEL_JIT'] = j
            log, _ = port(ops_args(ops) + ['--op', f'file.export_stl {st}'], env, binary=REL)
            ms = [float(x) for x in re.findall(r'geometry nodes: ([0-9.]+) ms', log)]
            times.append((j or 'avx', min(ms) if ms else -1))
            t = tris(st)
            hs.append(hashlib.md5(b''.join(t)).hexdigest() if t else None)
            if os.path.exists(st):
                os.remove(st)  # (100 MB)
        check(hs[0] is not None and len(set(hs)) == 1, f'{name}: the JIT, the SSE JIT and the interpreter give the same bits ({len(set(hs))} results)')
        print('       ms (one CPU, the tree)' + ('' if REL else ' [debug build]') + ': ' + ', '.join(f'{j} {t:.1f}' for j, t in times))


# ---- s_ntre -------------------------------------------------------------------------------

def save(name, ops):
    """The operators run, the scene saved, opened and saved again: (first file, second) or None."""
    b, c = f'{T}/p_{name}.bee', f'{T}/q_{name}.bee'
    for f in (b, c):
        if os.path.exists(f):
            os.remove(f)
    port(ops_args(ops) + ['--op', f'file.save_as {b}'])
    if not os.path.exists(b):
        return None, None
    port(['--op', f'file.open {b}', '--op', f'file.save_as {c}'])
    return b, (c if os.path.exists(c) else None)


def same_chunks(a, b, tags=(b'NTRE', b'MODS')):
    return all(beefile.chunk(a, t) == beefile.chunk(b, t) for t in tags)


def s_ntre():
    print('-- tree.group and tree.node: saved, opened, saved: NTRE and MODS byte for byte --')
    base = [('tree.new', 'T')] + N('T', 'output', 'grid 3 5', 'set_position', 'position', 'separate_xyz', 'math 2', 'combine_xyz', 'normal', 'transform 10', 'input') + \
        L('T', '2 3 1', '4 5 1', '5:1 6 1', '6 7 2', '7 3 3', '8 3 2', '3 9 1', '9 1 1') + [('tree.node_move', 'T 3 100 -40'), ('tree.node_move', 'T 6 33 77'), ('tree.node_move', 'T 9 -12 5')]
    cases = {
        'group a field': base + [('tree.group', 'T 3 4 5 6 7')],
        'group with the input and output': base + [('tree.group', 'T 1 2 3 10')],
        'group the fields only': base + [('tree.group', 'T 6 7 8')],
        'group the last': base + [('tree.group', 'T 9')],
        'group nothing valid': base + [('tree.group', 'T 0 99 -3 1')],
        'groups twice': base + [('tree.group', 'T 3'), ('tree.group', 'T 2 3')],
        'every type': [('tree.new', 'T')] + N('T', 'input', 'output', 'grid 1 2 3 4', 'cube', 'sphere', 'cylinder', 'line 3 1 2 3', 'transform', 'join', 'set_position',
                                               'extrude', 'subdivide', 'boolean', 'merge', 'realize', 'position', 'normal', 'index', 'value 7', 'combine_xyz', 'separate_xyz',
                                               'math 3', 'vector_math 4', 'noise', 'random', 'group', 'distribute', 'instance', 'curve_line', 'curve_circle', 'curve_to_mesh',
                                               'resample', 'trim', 'fillet', 'curve_to_points', 'terrain', 'terrace', 'erode', 'lsystem', 'bogus'),
        'a full tree': [('tree.new', 'T')] + N('T', *['cube'] * 50) + [('tree.group', 'T ' + ' '.join(str(k) for k in range(1, 49)))],
        'the modifier': base + MOD + [('object.modifier_set', '0 tree 7'), ('object.modifier_add_geometry', ''), ('object.modifier_add_logic', '')],
    }
    bad = []
    nt = {}
    for name, ops in cases.items():
        a, b = save(re.sub(r'[^a-z]', '_', name), ops)
        if a is None or b is None or not same_chunks(a, b) or beefile.chunk(a, b'NTRE') is None:
            bad.append(name)
        else:
            nt[name] = beefile.chunk(a, b'NTRE')
    check(not bad, f'{len(cases)} cases: saved, opened and saved again, the same NTRE and MODS ({bad})')
    g = [k for k in cases if k.startswith('group') and k != 'group nothing valid']
    check(len({nt.get(k) for k in g}) == len(g), f'each grouping a tree of its own ({len({nt.get(k) for k in g})} of {len(g)})')


# ---- s_fuzz -------------------------------------------------------------------------------

def random_trees(R):
    vals = {
        'grid': lambda: [R.choice([0.5, 1, 2, 3.5]), R.randint(0, 12)], 'cube': lambda: [R.choice([0.3, 1, 2])], 'sphere': lambda: [R.choice([0.3, 1, 1.5])],
        'cylinder': lambda: [R.choice([0.3, 1]), R.choice([0.5, 2])], 'line': lambda: [R.randint(-1, 30), R.uniform(-1, 1), R.uniform(-1, 1), R.uniform(-1, 1)],
        'transform': lambda: [R.uniform(-180, 180), R.uniform(-180, 180), R.uniform(-180, 180)], 'subdivide': lambda: [R.randint(-1, 2)],
        'boolean': lambda: [R.randint(-1, 3)], 'merge': lambda: [R.choice([0, 0.001, 0.1, 0.5])], 'value': lambda: [R.uniform(-2, 2)],
        'math': lambda: [R.randint(-1, 16)], 'vector_math': lambda: [R.randint(-1, 11)], 'noise': lambda: [R.uniform(0.1, 5), R.randint(0, 9), R.uniform(0, 1)],
        'random': lambda: [R.uniform(-1, 1), R.uniform(-1, 2), R.randint(-5, 50)], 'distribute': lambda: [R.uniform(-1, 40), R.randint(0, 99), R.choice([0, 0, 0.05, 0.2])],
        'instance': lambda: [R.randint(0, 1), R.randint(0, 1), R.randint(0, 9)], 'group': lambda: [R.randint(0, 3)],
        'curve_circle': lambda: [R.randint(-1, 20), R.uniform(0.2, 2)], 'curve_to_mesh': lambda: [R.uniform(0, 0.3), R.randint(0, 8), R.randint(0, 1)],
        'resample': lambda: [R.randint(-1, 20), R.choice([0, 0.2, 0.5])], 'trim': lambda: [R.uniform(-0.2, 1), R.uniform(0, 1.2)],
        'fillet': lambda: [R.uniform(0, 0.4), R.randint(0, 5)], 'curve_to_points': lambda: [R.randint(-1, 20)],
        'terrain': lambda: [R.uniform(1, 5), R.randint(1, 20), R.uniform(0, 2), R.randint(0, 9)], 'terrace': lambda: [R.randint(0, 8), R.uniform(0, 0.5)],
        'erode': lambda: [R.randint(0, 600), R.uniform(0, 0.5), R.randint(0, 9)], 'lsystem': lambda: [R.randint(0, 3), R.randint(0, 2), R.choice([0, 0.03]), R.uniform(0.05, 0.2)],
    }
    # (no Extrude here: its result differs on purpose, see s_nodes)
    geo = ['grid', 'cube', 'sphere', 'cylinder', 'line', 'transform', 'join', 'set_position', 'subdivide', 'boolean', 'merge', 'realize', 'distribute', 'instance', 'input', 'group',
           'curve_line', 'curve_circle', 'curve_to_mesh', 'resample', 'trim', 'fillet', 'curve_to_points', 'terrain', 'terrace', 'erode', 'lsystem']
    field = ['position', 'normal', 'index', 'value', 'combine_xyz', 'separate_xyz', 'math', 'vector_math', 'noise', 'random']

    def one(name, nn):
        ops = [('tree.new', name), ('tree.node', name + ' output')]
        types = ['output']
        for _ in range(nn):
            t = R.choice(geo) if R.random() < 0.55 else R.choice(field)
            if t == 'subdivide' and R.random() < 0.5:
                t = 'merge'
            types.append(t)
            v = ' '.join('%g' % x for x in vals.get(t, lambda: [])())
            ops.append(('tree.node', f'{name} {t} {v}'.strip()))
            node = len(types)
            for inp in (1, 2, 3):
                if node > 2 and R.random() < 0.6:
                    ops.append(('tree.link', '%s %d:%d %d %d' % (name, R.randint(2, node - 1), R.choice([0, 0, 0, 1, 2]), node, inp)))
                elif R.random() < 0.3:
                    ops.append(('tree.node_set', '%s %d %d %g %g %g' % (name, node, inp, R.uniform(-1, 1), R.uniform(-1, 1), R.uniform(-1, 1))))
        g = [i + 1 for i, t in enumerate(types) if t in geo]
        if g:
            ops.append(('tree.link', '%s %d 1 1' % (name, R.choice(g[-3:]))))
        return ops
    return one('T', R.randint(3, 10)) + one('G', R.randint(2, 6)) + one('H', R.randint(2, 5)) + MOD


def s_fuzz():
    print(f'-- random trees (seed {SEED}, {RUNS}) --')
    R = random.Random(SEED)
    bad = []
    for r in range(RUNS):
        ops = random_trees(R)
        b, fin, rc = stl('fz', ops)
        b2 = stl('fz2', ops)[0] if r < 4 else b
        if b is None or not fin or rc != 0 or b2 != b:
            bad.append(r)
            open(f'{T}/fuzz_{r}.ops', 'w').write(repr(ops))
    check(not bad, f'{RUNS} random trees: no crash, the triangles finite (the first 4 the same twice) ({bad})')


# ---- s_files, s_undo, s_damaged -------------------------------------------------------------

SCENE = cases_nodes()['join+transform instances'][:-2] + N('T', 'subdivide 1') + MOD


def s_files():
    print('-- files: saved and opened again --')
    a, b = save('files', SCENE)
    check(a is not None and b is not None and same_chunks(a, b), 'the scene saved, opened and saved again: the same NTRE and MODS')
    if a is None:
        return
    pa, pb = f'{T}/fpo.stl', f'{T}/fpd.stl'
    for f in (pa, pb):
        if os.path.exists(f):
            os.remove(f)
    port(['--op', f'file.open {a}', '--op', f'file.export_stl {pa}'])
    port(ops_args(SCENE) + ['--op', f'file.export_stl {pb}'])
    t = [tris(x) for x in (pa, pb)]
    check(t[0] is not None and len(t[0]) > 100 and t[0] == t[1],
          f'the file opened: the same triangles as the scene it was saved from ({[None if x is None else len(x) for x in t]})')


def s_undo():
    print('-- undo and redo --')
    steps = [('tree.node_set', 'T 9 4 45'), ('tree.group', 'T 2 3 4')]
    pre = [(f'{T}/ou{k}.bee', SCENE + steps[:k]) for k in range(3)]
    for p, ops in pre:
        if os.path.exists(p):
            os.remove(p)
        port(ops_args(ops) + ['--op', f'file.save_as {p}', '--op', f'file.export_stl {p}.stl'])
    a = ops_args(SCENE)
    sv = lambda k: ['--op', f'file.save_as {T}/u{k}.bee', '--op', f'file.export_stl {T}/u{k}.stl']
    a += sv(1) + ops_args(steps[:1]) + sv(2) + ops_args(steps[1:]) + sv(3) + ['--op', 'edit.undo'] + sv(4) + ['--op', 'edit.undo'] + sv(5)
    a += ['--op', 'edit.redo'] + sv(6) + ['--op', 'tree.node T bogus', '--op', 'tree.link T 3 3 1', '--op', 'tree.group T 0 1', '--op', 'tree.node_set Nope 1 1 1']
    a += ['--op', 'edit.undo'] + sv(7) + ['--op', 'object.modifier_set 0 tree 0'] + sv(8) + ['--op', 'edit.undo'] + sv(9)
    for k in range(1, 10):
        for x in (f'{T}/u{k}.bee', f'{T}/u{k}.stl'):
            if os.path.exists(x):
                os.remove(x)
    port(a)
    ok = all(os.path.exists(f'{T}/u{k}.bee') for k in range(1, 10)) and all(os.path.exists(p) for p, _ in pre)
    if not ok:
        check(False, 'the undo states saved')
        return
    ch = {k: (beefile.chunk(f'{T}/u{k}.bee', b'NTRE'), beefile.chunk(f'{T}/u{k}.bee', b'MODS')) for k in range(1, 10)}
    oc = [(beefile.chunk(p, b'NTRE'), beefile.chunk(p, b'MODS')) for p, _ in pre]
    st = {k: tris(f'{T}/u{k}.stl') for k in range(1, 10)}
    ot = [tris(p + '.stl') for p, _ in pre]
    check(ch[1] == oc[0] and ch[2] == oc[1] and ch[3] == oc[2] and st[1] == ot[0] and st[2] == ot[1] and st[3] == ot[2],
          'each step as the same steps make it afresh: the same NTRE, MODS and triangles')
    check(ch[4] == ch[2] and ch[5] == ch[1] and ch[6] == ch[2] and st[4] == st[2] and st[5] == st[1] and st[6] == st[2] and st[1] != st[2],
          'tree.group and tree.node_set undone and redone: the trees and the mesh as they were each time')
    check(ch[7] == ch[1], 'operators that fail make no step: the undo after them takes the node_set back')
    check(st[8] != st[7] and st[9] == st[7] and ch[9] == ch[7], 'the modifier\'s tree set to none and undone: the mesh follows')


def write_bee(path, chs):
    with open(path, 'wb') as f:
        f.write(b'BEEM' + struct.pack('<I', 1))
        for t, b in chs:
            f.write(t + struct.pack('<I', len(b)) + b)


def s_damaged():
    print('-- damaged NTRE chunks --')
    a, _ = save('dmgsrc', SCENE)
    if a is None:
        check(False, 'the scene to damage')
        return
    R = random.Random(SEED + 7)
    chs = beefile.chunks(a)
    ntre = beefile.chunk(a, b'NTRE')
    n = struct.unpack_from('<I', ntre)[0]
    cases = {'cut short': ntre[:4 + 2000], 'a count of 1000': struct.pack('<I', 1000) + ntre[4:], 'empty': b''}
    muts = {
        'links to nodes not there': lambda r, o: r.__setitem__(slice(o + 4 + 16 * R.randrange(3), o + 6 + 16 * R.randrange(3)), struct.pack('<H', R.randrange(1, 65535))),
        'links in loops': lambda r, o: r.__setitem__(slice(o + 4 + 16 * R.randrange(3), o + 8 + 16 * R.randrange(3)), struct.pack('<I', R.randrange(1, 16) | R.randrange(0, 5) << 16)),
        'types past the last': lambda r, o: r.__setitem__(slice(o, o + 4), struct.pack('<I', R.choice([0, 40, 99, 0xffffffff, 26]))),
        'NaN and huge values': lambda r, o: r.__setitem__(slice(o + 52, o + 68), struct.pack('<4f', float('nan'), 1e30, -1e30, float('inf'))),
        'NaN constants': lambda r, o: r.__setitem__(slice(o + 8, o + 20), struct.pack('<3f', float('nan'), float('inf'), -0.0)),
    }
    for name, mut in muts.items():
        r = bytearray(ntre)
        for k in range(n):
            base = 4 + k * 4096
            nn = struct.unpack_from('<I', r, base + 128)[0]
            for j in range(min(nn, 48)):
                if R.random() < 0.5:
                    mut(r, base + 160 + j * 72)
        cases[name] = bytes(r)
    r = bytearray(ntre)
    r[4 + 128:4 + 132] = struct.pack('<I', 49)
    cases['a node count past 48'] = bytes(r)
    bad = []
    for name, data in cases.items():
        path = f'{T}/dmg.bee'
        write_bee(path, [(t, data if t == b'NTRE' else b) for t, b in chs])
        pb = f'{T}/dp.stl'
        if os.path.exists(pb):
            os.remove(pb)
        _, rc = port(['--op', f'file.open {path}', '--op', f'file.export_stl {pb}'])
        y = tris(pb)
        if rc != 0 or y is None:
            bad.append((name, rc, None if y is None else len(y)))
    for x in bad:
        print('      ', x)
    check(not bad, f'{len(cases)} damaged files: opened, evaluated, exported; no crash')


# ---- s_window -------------------------------------------------------------------------------

def s_window():
    print('-- the window: the Modifiers tab, the instances in the viewport --')
    from PIL import Image
    inst = tree(N('T', 'sphere 1', 'distribute 30 1 0', 'cube 0.12', 'instance 1 1 4'), L('T', '2 3 1', '3 5 1', '4 5 2', '5 1 1'))
    plain = [('object.modifier_add_geometry', ''), ('object.modifier_set', '0 tree 0')]
    a, _ = save('win', inst + MOD)
    b, _ = save('win0', inst + plain)
    if a is None or b is None:
        check(False, 'the scenes for the window')
        return
    # the Modifiers tab: the modifier by name, its tree by name, Add Modifier's list
    ui = f'{T}/ui.txt'
    h = home()
    subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/pm.ppm', '--op', f'file.open {a}', '--click-label', 'Modifiers', '--move', '600,300', '--dump-ui', ui], env=dict(os.environ, HOME=h), capture_output=True)
    shutil.rmtree(h, True)
    rows = open(ui).read() if os.path.exists(ui) else ''
    check('checkbox\tGeo Nodes\t' in rows and re.search(r'button\tT\t', rows) is not None,
          'the Modifiers tab: Geo Nodes, its Tree row naming the tree T')
    # the viewport: the instances drawn every tile's own way, against the
    # striped way (BEEMODEL_INST_TILES=orig: the tiles read one off). Big ones
    # (triangles), then tiny ones (splats).
    tiny = tree(N('T', 'grid 3 1', 'distribute 400 3 0', 'cube 0.006', 'instance 0 0 0'), L('T', '2 3 1', '3 5 1', '4 5 2', '5 1 1'))
    c, _ = save('wint', tiny + MOD)
    d, _ = save('wint0', tiny + plain)
    view_compare('triangles', a, b, 1.5)
    if c and d:
        view_compare('splats', c, d, 1.2)


def view_compare(what, a, b, more):
    from PIL import Image
    for f, p, env in ((a, 'pw', {}), (a, 'pwo', {'BEEMODEL_INST_TILES': 'orig'}), (b, 'pw0', {})):
        h = home()
        subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/{p}.ppm', '--move', '600,300', '--op', 'area.maximize', '--op', f'file.open {f}'], env=dict(os.environ, HOME=h, **env), capture_output=True)
        shutil.rmtree(h, True)
    if not all(os.path.exists(x) for x in (f'{T}/pw.ppm', f'{T}/pwo.ppm', f'{T}/pw0.ppm')):
        check(False, f'{what}: the three shots')
        return
    im = {k: Image.open(f'{T}/{k}.ppm').convert('RGB') for k in ('pw', 'pwo', 'pw0')}
    px = {k: v.load() for k, v in im.items()}
    w, hh = im['pw'].size
    # where the instances are: what the tree adds to the picture
    box = [w, hh, 0, 0]
    for y in range(130, hh - 80):
        for x in range(100, w - 120):
            if sum(abs(px['pw'][x, y][c] - px['pw0'][x, y][c]) for c in range(3)) > 30:
                box = [min(box[0], x), min(box[1], y), max(box[2], x + 1), max(box[3], y + 1)]
    inst_px = lambda p: min(p) > 100 and max(p) - min(p) < 25
    cnt = {k: set() for k in ('pw', 'pwo')}
    for y in range(max(box[1] - 4, 0), min(box[3] + 4, hh)):
        for x in range(max(box[0] - 4, 0), min(box[2] + 4, w)):
            for k in cnt:
                if inst_px(px[k][x, y]):
                    cnt[k].add((x, y))
    if what == 'splats':
        # (a splat: COL_SOLID x 0.85)
        sp = sum(1 for q in cnt['pw'] if px['pw'][q] == (162, 165, 171))
        check(len(cnt['pw']) > 1000 and sp * 100 >= 95 * len(cnt['pw']) and len(cnt['pwo']) < len(cnt['pw']),
              f'splats: squares in the splat colour ({sp} of {len(cnt["pw"])}; the striped way {len(cnt["pwo"])})')
        return
    check(len(cnt['pwo']) > 100, f'{what}: the instances drawn ({len(cnt["pwo"])} pixels the striped way)')
    check(len(cnt['pw']) > len(cnt['pwo']) * more,
          f'{what}, drawn every tile\'s own way: more than the striped way ({len(cnt["pw"])} pixels, {len(cnt["pwo"])})')


def s_particles():
    print('-- particles drawn as objects (pt_iblock, inst_draw_ib) --')
    from PIL import Image
    os.environ['BEEMODEL_GPU'] = 'off'  # (the CPU's pictures)
    f = f'{T}/parts.bee'
    make('add("sphere", "Prop", 6, 0, 0)\nscale("Prop", 0.6, 0.3, 0.3)\nadd("cone", "Prop2", -6, 0, 0)\nselect("Cube")\n'
         'op("particles.add", "rate 60 life 4 speed 3 size 0.4 size_end 0.3 draw objects objects Prop,Prop2 align velocity")\n'
         'op("particles.add", "rate 40 life 4 speed 2 size 0.25 size_end 2 draw objects seed 7")\n'
         f'op("file.save_as", "{f}")')
    if not os.path.exists(f):
        check(False, 'the scene made')
        return
    frame = 40
    a = ['--move', '600,300', '--op', 'area.maximize', '--op', f'file.open {f}', '--op', f'anim.frame {frame}']
    off = ['--select', 'Cube', '--op', 'particles.set system 1 off', '--op', 'particles.set system 2 off', '--op', f'anim.frame {frame}']
    for name, extra, env in (('pp1', [], {'BEEMODEL_INST_TILES': 'orig'}), ('pp0', off, {}), ('pq1', [], {}), ('pq2', [], {})):
        h = home()
        subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/{name}.ppm', *a, *extra], env=dict(os.environ, HOME=h, **env), capture_output=True)
        shutil.rmtree(h, True)
    if not all(os.path.exists(f'{T}/{x}') for x in ('pp1.ppm', 'pp0.ppm', 'pq1.ppm', 'pq2.ppm')):
        check(False, 'the shots')
        return

    def mask(p1, p0):
        A_, B_ = Image.open(p1).convert('RGB'), Image.open(p0).convert('RGB')
        pa, pb = A_.load(), B_.load()
        w, hh = A_.size
        return {(x, y): pa[x, y] for y in range(130, hh - 80) for x in range(100, w - 120) if max(abs(pa[x, y][c] - pb[x, y][c]) for c in range(3)) > 12}
    if os.environ.get('GN_KEEP'):
        for x in ('pp1.ppm', 'pp0.ppm', 'pq1.ppm'):
            shutil.copy(f'{T}/{x}', os.environ['GN_KEEP'])
    mp, mq = mask(f'{T}/pp1.ppm', f'{T}/pp0.ppm'), mask(f'{T}/pq1.ppm', f'{T}/pp0.ppm')
    check(len(mp) > 200, f'at frame {frame} the particles drawn as objects change the picture ({len(mp)} pixels, the striped way)')
    check(len(mq) > len(mp) * 1.2, f'drawn every tile\'s own way: those moving straight up or down too ({len(mq)} pixels, the striped way {len(mp)})')
    check(open(f'{T}/pq1.ppm', 'rb').read() == open(f'{T}/pq2.ppm', 'rb').read(), 'the same frame drawn twice: the same picture')


def s_rbody():
    print('-- instances as rigid bodies (inst_bodies, inst_writeback, the cache) --')
    t = tree(N('T', 'grid 3 2', 'cube 0.35', 'instance 1 0 3', 'random 0.6 1.4 5'), L('T', '2 4 1', '3 4 2', '6 4 3', '4 1 1'))
    setup = ('add("plane", "Ground", 0, 0, 0)\nscale("Ground", 8)\nadd("cube", "L", 0.3, 3, -0.2)\nrotate("L", 0.3, 0.5, 0.1)\nscale("L", 1, 1.2, 0.9)\n'
             'select("L")\n' + ops_code(t + MOD) + '\nselect("Ground")\nop("rigid.add", "passive plane")\nselect("L")\nop("rigid.add", "active box instances")\n')
    frames = [1, 8, 25, 50]
    code = setup
    for k, f in enumerate(frames):
        code += f'frame({f})\nprint("I", rbinfo(16), rbinfo(0), instances("L"), instpos("L", 3, 1) * 1000000000, instpos("L", 7, 0) * 1000000000)\nop("file.save_as", "{T}/rbo{k}.bee")\n'
    code += f'op("sim.bake", "")\nop("file.save_as", "{T}/rbob.bee")\n'
    out = make(code)
    io = re.findall(r'^I (.*)$', out, re.M)
    # the timeline: the same scene from the script's first file
    if not os.path.exists(f'{T}/rbo0.bee'):
        check(False, 'the script made the scene')
        return
    a = ['--op', f'file.open {T}/rbo0.bee']
    for k, f in enumerate(frames):
        a += ['--op', f'anim.frame {f}', '--print-anim', 'rbinfo:16', '--print-anim', 'rbinfo:0', '--op', f'file.save_as {T}/rbp{k}.bee']
    a += ['--op', 'sim.bake', '--op', f'file.save_as {T}/rbpb.bee']
    h = home()
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{h}/x.ppm', *a], env=dict(os.environ, HOME=h), capture_output=True, text=True)
    shutil.rmtree(h, True)
    vals = re.findall(r'^rbinfo:(\d+)=(\S+)', r.stderr, re.M)
    ip = [(vals[k][1], vals[k + 1][1]) for k in range(0, len(vals) - 1, 2)]
    oi = [ln.split()[:2] for ln in io]
    same_hash = len(oi) == len(frames) and len(ip) == len(frames) and all(float(x[0]) == float(y[0]) and float(x[1]) == float(y[1]) for x, y in zip(oi, ip))
    check(r.returncode == 0 and same_hash, f'every body (9 instances and the ground) at frames {frames}: the same hash of their places, turns and speeds from a script and from the timeline ({oi} / {ip})')
    moved = len(io) == len(frames) and io[0].split()[3:] != io[-1].split()[3:]
    check(moved and io[0].split()[2] == '9', f'the 9 instances fell (instpos moves: {[ln.split()[2:] for ln in io[:1] + io[-1:]]})')
    # the viewport follows the bodies (inst_writeback): what changes from frame 1 to frame 50
    from PIL import Image
    for fr in (1, 50):
        h = home()
        subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/rp{fr}.ppm', '--move', '600,300', '--op', 'area.maximize', '--op', f'file.open {T}/rbo0.bee', '--op', 'anim.frame 1', '--op', f'anim.frame {fr}'],
                       env=dict(os.environ, HOME=h), capture_output=True)
        shutil.rmtree(h, True)

    def changed(a, b):
        if not (os.path.exists(a) and os.path.exists(b)):
            return set()
        A_, B_ = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
        pa, pb = A_.load(), B_.load()
        w, hh = A_.size
        return {(x, y) for y in range(130, hh - 80) for x in range(100, w - 120) if max(abs(pa[x, y][c] - pb[x, y][c]) for c in range(3)) > 30}
    mp = changed(f'{T}/rp1.ppm', f'{T}/rp50.ppm')
    check(len(mp) > 300, f'the instances drawn where they fell ({len(mp)} pixels changed from frame 1 to 50)')
    co, cp = (beefile.chunk(f'{T}/{x}.bee', b'SIMC') if os.path.exists(f'{T}/{x}.bee') else None for x in ('rbob', 'rbpb'))
    check(co is not None and len(co) > 10000 and co == cp,
          f'baked (sim.bake): the cache, every frame\'s instance matrices, the same from a script and from the timeline ({None if co is None else len(co)} / {None if cp is None else len(cp)} bytes)')


def s_unit():
    print('-- the unit tests of the modules (zig test) --')
    src = os.environ.get('GN_SRC', ROOT)
    bad = []
    for f in ('fieldvm', 'geonodes', 'inst'):
        r = subprocess.run(['zig', 'test', f'src/{f}.zig', '--cache-dir', f'{T}/zc'], cwd=src, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append((f, (r.stderr or r.stdout)[-200:]))
    shutil.rmtree(f'{T}/zc', True)
    check(not bad, f'src/fieldvm.zig, src/geonodes.zig, src/inst.zig: their tests pass {bad}')


def s_render():
    print('-- the path tracer: instances as triangles --')
    from PIL import Image
    inst = tree(N('T', 'grid 3 3', 'cube 0.3', 'instance 1 0 7'), L('T', '2 4 1', '3 4 2', '4 1 1'))
    real = tree(N('T', 'grid 3 3', 'cube 0.3', 'instance 1 0 7', 'realize'), L('T', '2 4 1', '3 4 2', '4 5 1', '5 1 1'))
    imgs = {}
    for name, ops in (('inst', inst + MOD), ('real', real + MOD), ('none', inst + [('object.modifier_add_geometry', ''), ('object.modifier_set', '0 tree 0')])):
        png = f'{T}/r_{name}.png'
        h = home()
        subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/r.ppm', *ops_args(ops), '--op', 'render.settings 96 72 16', '--move', '615,360', '--key', 'f12', '--render-wait',
                        '--op', f'render.save {png}'], env=dict(os.environ, HOME=h), capture_output=True)
        shutil.rmtree(h, True)
        imgs[name] = list(Image.open(png).convert('RGB').getdata()) if os.path.exists(png) else None
    if any(v is None for v in imgs.values()):
        check(False, 'the three renders')
        return
    d = lambda a, b: sum(abs(x[c] - y[c]) for x, y in zip(imgs[a], imgs[b]) for c in range(3)) / (len(imgs[a]) * 3)
    check(d('inst', 'real') < 1.0 and d('inst', 'none') > 4 * max(d('inst', 'real'), 0.5),
          f'instances rendered as their realized triangles (mean difference {d("inst", "real"):.2f}; without them {d("inst", "none"):.2f})')


def main():
    print(f'geonodes: {BIN}, seed {SEED}')
    for name, f in (('s_nodes', s_nodes), ('s_vm', s_vm), ('s_ntre', s_ntre), ('s_fuzz', s_fuzz), ('s_files', s_files), ('s_undo', s_undo), ('s_damaged', s_damaged), ('s_window', s_window), ('s_render', s_render), ('s_particles', s_particles), ('s_rbody', s_rbody), ('s_unit', s_unit)):
        if want(name):
            t0 = time.time()
            f()
            print(f'       ({name}: {time.time() - t0:.0f} s)')
    shutil.rmtree(T, True)
    print(f'geonodes fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
