#!/usr/bin/env python3
"""Shader node graphs (shgraph, material graphs, functions, instances): each
session runs twice in BeeModel, as a BeeScript (--run: op, nodeval) and from
the command line (--op, --dump-nodeval). Random sessions of every graph
command (all 42 node types, links, values, pins, deletes, places, parameter
names and values, instances, functions, make_function) give the same MATS and
MGRF bytes both ways; each node's every output at random points is the same
bits both ways (functions, parameters, instances, folded constants); save ->
open -> save keeps the graphs; undo and redo of graph edits give back the
graphs before and after; damaged MGRF chunks are read without a stop, the
same both ways; the Material tab of an instance; renders of graphs using
every node type within BeeModel's own noise; Material Preview; a fuzz.

    python3 tests/shnodes.py BIN [sessions=12] [seed]

BEE_CPU (default 12) pins every run; SH_ONLY=s_bytes,s_eval,... runs some.
"""
import os, random, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('SH_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beeshn-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
TEX = os.path.join(ROOT, 'tests', 'files', 'oracle_tex.png')

TYPES = ["image", "noise", "checker", "gradient", "mix", "ramp", "math", "bump", "normalmap", "texcoord", "position", "normal", "camera", "vcolor", "time", "constant", "color", "fresnel", "vmath", "separate", "combine", "mapping", "panner", "rotator", "voronoi", "hsv", "invert", "brightcon", "desaturate", "gamma", "blackbody", "brick", "wave", "whitenoise", "triplanar", "reroute", "scalarparam", "vectorparam", "textureparam", "fninput", "fnoutput", "fncall"]
PINS = ["base", "metallic", "specular", "roughness", "emission", "opacity", "normal", "ao", "clearcoat", "coat_roughness", "transmission", "ior", "mask"]


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def script(code, timeout=900):
    """A BeeScript run by BeeModel (--run): its output and errors."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code + '\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, 'the BeeScript hung')
        return 'timeout'
    if r.returncode not in (0, 1) or 'panic' in r.stderr:
        check(False, f'the BeeScript run stopped ({r.returncode}): {r.stderr[-300:]}')
    return r.stdout + r.stderr


def port(*a, timeout=900, shot=None):
    args = ['taskset', '-c', CPU, BIN, '--shot', shot or f'{T}/u.ppm', '--dump-log', f'{T}/log.txt'] + list(a)
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        print(r.stderr[-1500:])
    return r.returncode


def portlog():
    try:
        return open(f'{T}/log.txt').read()
    except OSError:
        return ''


def opsargs(ops):
    out = []
    for i, a in ops:
        out += ['--op', f'{i} {a}'.strip()]
    return out


def opsscript(ops, frames=True):
    """The commands as a BeeScript. frames: a frame between each two, as --op
    has (a console line: undo.sync) - the material sync, through matget, which
    calls it first. Without it a --run script never syncs, and a command on an
    instance made before its parent changed sees the stale graph."""
    out, mat = [], None
    for i, a in ops:
        if frames and mat:
            out.append(f'matget("{mat}", "roughness")')
        out.append(f'op("{i}", "{a}")')
        if mat is None and i in ('material.new', 'material.function_new') and a.split():
            mat = a.split()[0]
    return '\n'.join(out)


def graphs(path):
    """MATS and MGRF of a file."""
    return beefile.chunk(path, b'MATS'), beefile.chunk(path, b'MGRF')


def first_diff(a, b):
    if a is None or b is None:
        return 'missing'
    i = next((k for k, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    return f'at byte {i} of {len(a)} / {len(b)}'


# ---- random sessions --------------------------------------------------------------------

def num(r):
    k = r.random()
    if k < 0.3:
        return str(r.randrange(-3, 12))
    if k < 0.6:
        return '%g' % (r.randrange(-64, 256) / 16)
    if k < 0.8:
        return '%.3f' % r.uniform(-2, 4)
    return '%g' % r.choice([0, 1, 0.5, 2, 30, 6500, 1e-6, -1, 100, 0.04])


def session(r, n_ops=70, out0=False, inst=True):
    """A random session: the commands (id, argument) and the material names."""
    ops = [('image.load', TEX), ('material.function_new', 'Fn')]
    mats = ['A', 'B', 'C']
    for m in mats:
        ops.append(('material.new', m))
    # the function: x -> (x * 2, x + noise, its sine)
    ops += [('material.node', 'Fn math 2'), ('material.node_set', 'Fn 3 2 2'), ('material.link', 'Fn 1 3 1 0'), ('material.link', 'Fn 3 2 1 0'),
            ('material.node', 'Fn fninput 1'), ('material.node', 'Fn noise 3 2 0.5'), ('material.link', 'Fn 5 6 1 0'), ('material.link', 'Fn 6 2 2 0')]
    counts = {m: 0 for m in mats}
    pnames = ['Wear', 'Tint', 'Rough', 'Tex', 'P']
    insts = []
    for _ in range(n_ops):
        m = r.choice(mats + insts) if insts and r.random() < 0.15 else r.choice(mats)
        n = counts.get(m, 0)
        k = r.random()
        if k < 0.38 or n < 3:
            t = r.choice(TYPES)
            words = [m, t]
            if t in ('scalarparam', 'vectorparam', 'textureparam'):
                words.append(r.choice(pnames))
            # (an image node names its image first: a number there adds nothing)
            named = t not in ('image', 'textureparam') or r.random() < 0.8
            if t in ('image', 'textureparam') and named:
                words.append('oracle_tex')
            if t == 'fncall':
                words.append(r.choice(['Fn', 'Fn', 'A']))
            for _ in range(r.randrange(0, 5) if named else 0):
                words.append(num(r))
            ops.append(('material.node', ' '.join(words)))
            counts[m] = min(48, n + 1)
        elif k < 0.62:
            a, b = r.randrange(1, n + 2), r.randrange(1, n + 2)
            ops.append(('material.link', f'{m} {a} {b} {r.randrange(1, 4)} {0 if out0 else r.choice([0, 0, 0, 1, 2, 3, 4, 7])}'))
        elif k < 0.74:
            vals = ' '.join(num(r) for _ in range(r.choice([1, 1, 3])))
            ops.append(('material.node_set', f'{m} {r.randrange(1, n + 1)} {r.randrange(1, 8)} {vals}'))
        elif k < 0.82:
            nd = r.choice(['none', str(r.randrange(1, n + 1))])
            ops.append(('material.socket', f'{m} {r.choice(PINS)} {nd} {0 if out0 else r.choice([0, 0, 1, 2, 3])}'))
        elif k < 0.85:
            ops.append(('material.node_delete', f'{m} {r.randrange(1, n + 1)}'))
            counts[m] = max(0, n - 1)
        elif k < 0.88:
            ops.append(('material.node_move', f'{m} {r.randrange(0, n + 1)} {r.randrange(-300, 900)} {r.randrange(-200, 700)}'))
        elif k < 0.90:
            ops.append(('material.node_name', f'{m} {r.randrange(1, n + 1)} {r.choice(pnames)}'))
        elif k < 0.93:
            ops.append(('material.param', f'{m} {r.choice(pnames)} ' + ' '.join(num(r) for _ in range(r.randrange(1, 5)))))
        elif k < 0.94:
            ops.append(('material.param_reset', f'{m} {r.choice(pnames)}'))
        elif k < 0.955 and len(insts) < 3 and m in mats and inst:
            nm = f'{m}I{len(insts)}'
            ops.append(('material.instance', f'{m} {nm}'))
            insts.append(nm)
            counts[nm] = n
        elif k < 0.985:
            sel = ' '.join(str(r.randrange(1, n + 1)) for _ in range(r.randrange(1, 5)))
            ops.append(('material.make_function', f'{m} {sel}'))
            counts[m] = n  # (an estimate: the tests read the file)
        else:
            ops.append(('material.nodes_clear', m))
            counts[m] = 0
    return ops, mats + insts + ['Fn']


def unreadable(path):
    """The materials whose graph, as saved, graph_check clears when the file is
    read back (a link to a later node, ...)."""
    mats, g = graphs(path)
    if not mats or not g or len(g) < 12:
        return []
    n = struct.unpack_from('<I', mats)[0]
    names = [mats[4 + k * 128:4 + k * 128 + 32].split(b'\0')[0].decode() for k in range(n)]
    out = []
    o = 12
    for k in range(min(struct.unpack_from('<I', g, 8)[0], n)):
        nn = struct.unpack_from('<I', g, o)[0]
        rec = g[o + 4:o + 4 + 32 + nn * 72 + 480]
        bad = nn > 48
        for p in struct.unpack_from('<16I', rec, 32 + nn * 72) if not bad else ():
            bad = bad or p & 0xff000000 or p & 0xf80000 or (p & 0xffff) > nn
        for i in range(nn if not bad else 0):
            t = struct.unpack_from('<I', rec, 32 + i * 72)[0]
            bad = bad or not 1 <= t <= 42
            for q in range(3):
                l = struct.unpack_from('<I', rec, 32 + i * 72 + 4 + q * 16)[0]
                bad = bad or l & 0xfff80000 or (l & 0xffff) > i
        if bad:
            out.append(names[k])
        o += 4 + 32 + nn * 72 + 480
    return out


def refused():
    """The make_function commands refused on the command line (they would leave a loop)."""
    return re.findall(r'make_function (.+?): those nodes would make a loop', portlog())


def same_session(ops, o, z, tag):
    """The command line's graphs against the BeeScript's: (same, note)."""
    a, b = graphs(o), graphs(z)
    if a == b:
        return True, ' (a make_function that loops refused)' if refused() else ''
    return False, f'MATS {first_diff(a[0], b[0])}, MGRF {first_diff(a[1], b[1])}'


def run_both(ops, tag):
    """The session both ways: (the BeeScript's file, the command line's)."""
    o, z = f'{T}/{tag}_o.bee', f'{T}/{tag}_z.bee'
    for p in (o, z):
        if os.path.exists(p):
            os.remove(p)
    script(opsscript(ops + [('file.save', o)]))
    port(*opsargs(ops + [('file.save', z)]))
    return o, z


def s_undo():
    print('-- undo and redo of graph commands: each step back is the file of the commands before it --')
    r = random.Random(SEED + 3)
    for s in range(max(1, RUNS // 4)):
        # commands that each change something (one undo step each)
        ops = [('image.load', TEX), ('material.function_new', 'Fn'), ('material.new', 'A'), ('material.new', 'B')]
        n = {'A': 0, 'B': 0}
        for i in range(30):
            m = r.choice('AB')
            k = r.random()
            if k < 0.4 or n[m] < 3:
                t = r.choice([x for x in TYPES if x not in ('image', 'textureparam')])
                nm = ' P%d' % i if t.endswith('param') else (' Fn' if t == 'fncall' else '')
                ops.append(('material.node', f'{m} {t}{nm} {i + 0.5}'))
                n[m] += 1
            elif k < 0.6:
                ops.append(('material.node_move', f'{m} {r.randrange(1, n[m] + 1)} {100 + i * 7} {i * 3 - 50}'))
            elif k < 0.75:
                ops.append(('material.node_set', f'{m} {r.randrange(1, n[m] + 1)} {r.randrange(1, 8)} {i * 0.25 + 0.125}'))
            elif k < 0.85:
                ops.append(('material.link', f'{m} {r.randrange(1, n[m])} {n[m]} {r.randrange(1, 4)} 0'))
            elif k < 0.92:
                ops.append(('material.node_delete', f'{m} {r.randrange(1, n[m] + 1)}'))
                n[m] -= 1
            else:
                ops.append(('material.make_function', f'{m} {n[m]}'))
                n[m] = n[m]
        # the graphs after each of the last 14 commands: which changed something
        W = 14
        P = {}
        a = opsargs(ops[:len(ops) - W])
        for j in range(len(ops) - W, len(ops) + 1):
            f = f'{T}/u{s}_p{j}.bee'
            a += ['--op', f'file.save_as {f}'] + (opsargs([ops[j]]) if j < len(ops) else [])
        port(*a)
        for j in range(len(ops) - W, len(ops) + 1):
            P[j] = graphs(f'{T}/u{s}_p{j}.bee')
        changed = [j for j in range(len(ops) - W + 1, len(ops) + 1) if P[j] != P[j - 1]]
        for k in (1, 3, 9):
            if k > len(changed):
                continue
            want = P[changed[-k] - 1]
            z = f'{T}/u{s}_{k}_z.bee'
            port(*opsargs(ops + [('edit.undo', '')] * k + [('file.save', z)]))
            zr = f'{T}/u{s}_{k}_zr.bee'
            port(*opsargs(ops + [('edit.undo', '')] * k + [('edit.redo', '')] * k + [('file.save', zr)]))
            b, c = graphs(z), graphs(zr)
            check(want == b and want[0] is not None, f'session {s}: {k} undo steps give the graphs before the last {k} changes ({first_diff(want[1], b[1])})')
            check(c == P[len(ops)], f'session {s}: and {k} redo steps the graphs after them')


def s_files():
    print('-- files: save -> open -> save keeps the graphs byte for byte, both ways --')
    r = random.Random(SEED + 4)
    for s in range(max(1, RUNS // 3)):
        ops, _ = session(r)
        o, z = run_both(ops, f'f{s}')
        z2, o2 = f'{T}/f{s}_z2.bee', f'{T}/f{s}_o2.bee'
        port('--op', f'file.open {o}', '--op', f'file.save {z2}')
        script(f'op("file.open", "{z}")\nop("file.save", "{o2}")')
        check(graphs(z2) == graphs(o) and graphs(o)[1] is not None, f'session {s}: the BeeScript\'s graphs opened and saved from the command line, byte for byte')
        check(graphs(o2) == graphs(z) and graphs(z)[1] is not None, f'session {s}: the command line\'s graphs opened and saved by a BeeScript, byte for byte')
        z3 = f'{T}/f{s}_z3.bee'
        port('--op', f'file.open {z2}', '--op', f'file.save {z3}')
        check(open(z2, 'rb').read() == open(z3, 'rb').read() if os.path.exists(z3) else False, f'session {s}: save -> open -> save gives the same file')


def rewrite(src, dst, tag, body):
    """A copy of a .bee file with one chunk's body replaced (stored plain)."""
    d = open(src, 'rb').read()
    out = bytearray(d[:8])
    for t, b in beefile.chunks(src):
        if t == tag:
            b = body
        out += t + struct.pack('<I', len(b)) + b
    open(dst, 'wb').write(bytes(out))


def v1_graphs(r, nmat):
    """An MGRF chunk in the v0.12 layout: 896 bytes a material, 12-node graphs,
    5 sockets (base, metallic, roughness, emission, normal) at byte 4."""
    out = bytearray(struct.pack('<I', nmat))
    for m in range(nmat):
        g = bytearray(896)
        n = r.randrange(0, 13)
        struct.pack_into('<I', g, 0, n)
        for i in range(n):
            t = r.randrange(1, 10)
            vals = [r.uniform(0, 4) for _ in range(4)]
            links = [(r.randrange(0, i + 1) if r.random() < 0.5 else 0) for _ in range(3)]
            o = 32 + i * 72
            struct.pack_into('<I', g, o, t)
            for k in range(3):
                struct.pack_into('<I3f', g, o + 4 + k * 16, links[k], r.random(), r.random(), r.random())
            struct.pack_into('<4f', g, o + 52, *vals)
        for c in range(5):
            if n and r.random() < 0.6:
                struct.pack_into('<I', g, 4 + c * 4, r.randrange(1, n + 1))
        if r.random() < 0.2 and n:  # (some nonsense: cleared)
            struct.pack_into('<I', g, 32 + 4, n + 3)
        out += g
    return bytes(out)


def s_damage():
    print('-- damaged MGRF chunks: never a stop, the same kept both ways --')
    r = random.Random(SEED + 5)
    ops, _ = session(r, 60, out0=True, inst=False)
    base = f'{T}/d_base.bee'
    script(opsscript(ops + [('file.save', base)]))
    g = beefile.chunk(base, b'MGRF')
    cases = [('v0.12 layout', v1_graphs(r, len(beefile.chunk(base, b'MATS')) // 128))]
    for cut in (0, 3, 4, 11, 12, 13, 40, len(g) // 2, len(g) - 1):
        cases.append((f'cut to {cut} bytes', g[:cut]))
    for i in range(14):
        b = bytearray(g)
        for _ in range(r.choice([1, 1, 3, 20])):
            k = r.randrange(12, len(b))
            b[k] = r.randrange(256)
        cases.append((f'garbage {i}', bytes(b)))
    b = bytearray(g)
    struct.pack_into('<I', b, 12, 49)
    cases.append(('49 nodes', bytes(b)))
    for t in (0, 43, 0xffffffff):
        b = bytearray(g)
        if struct.unpack_from('<I', b, 12)[0] > 0:
            struct.pack_into('<I', b, 48, t)  # (the first graph's first node)
        cases.append((f'a node of type {t}', bytes(b)))
    b = bytearray(g)
    struct.pack_into('<I', b, 8, 999)
    cases.append(('999 graphs', bytes(b)))
    survived = same = 0
    for name, body in cases:
        f = f'{T}/d.bee'
        rewrite(base, f, b'MGRF', body)
        o2, z2 = f'{T}/d_o2.bee', f'{T}/d_z2.bee'
        for p in (o2, z2):
            if os.path.exists(p):
                os.remove(p)
        out = script(f'op("file.open", "{f}")\nop("file.save", "{o2}")')
        rc = port('--op', f'file.open {f}', '--op', 'view.shading_material', '--op', f'file.save {z2}')
        check(rc == 0 and os.path.exists(z2), f'{name}: BeeModel reads it, draws it, saves it')
        check(os.path.exists(o2), f'{name}: a BeeScript opens it and saves it')
        if os.path.exists(o2):
            survived += 1
            ok = graphs(o2) == graphs(z2)
            same += ok
            check(ok, f'{name}: what it keeps is the same both ways ({first_diff(graphs(o2)[1], graphs(z2)[1])})')
    # every node of what was kept evaluates the same both ways (the v0.12 file, a garbage one)
    for name, body in cases[:1] + cases[10:12]:
        f, kept = f'{T}/dv.bee', f'{T}/dv_o.bee'
        rewrite(base, f, b'MGRF', body)
        script(f'op("file.open", "{f}")\nop("file.save", "{kept}")')
        ok, n = eval_compare(f, r, name, pts=2, ks=(0, 1, 2, 3), nodes_of=kept)
        check(ok == n, f'{name}: its nodes evaluate the same both ways ({ok} of {n})')


def s_window():
    print('-- the Material tab of an instance: an override toggle per parameter, a click, undo --')
    D = f'{T}/win'
    os.makedirs(D, exist_ok=True)
    f = f'{D}/inst.bee'
    ops = [('image.load', TEX), ('material.new', 'M'), ('material.node', 'M scalarparam Wear 0.25'), ('material.node', 'M vectorparam Tint 0.8 0.2 0.1'),
           ('material.node', 'M textureparam Tex oracle_tex'), ('material.node', 'M mix 0'), ('material.link', 'M 2 4 2 0'), ('material.link', 'M 3 4 3 0'),
           ('material.link', 'M 1 4 1 0'), ('material.socket', 'M base 4'), ('material.socket', 'M roughness 1'), ('material.instance', 'M MI'), ('file.save', f)]
    script(opsscript(ops))
    rc = port('--op', f'file.open {f}', '--select', 'Cube', '--click-label', 'tab:Material', '--move', '600,300', '--dump-ui', f'{D}/p.txt', shot=f'{D}/p.ppm')
    ui = open(f'{D}/p.txt').read() if os.path.exists(f'{D}/p.txt') else ''
    rows = [l.split('\t')[:2] for l in ui.splitlines()]
    have = lambda k, lb: [k, lb] in rows
    check(rc == 0 and have('info', 'Instance of M') and all(have('override', p) for p in ('Wear', 'Tint', 'Tex')),
          'the tab shows "Instance of M" and an override toggle per parameter (Wear, Tint, Tex)')
    check(have('colour', 'Tint') and not any(r[1] == 'Base colour' for r in rows), 'a vector parameter as a colour; nothing of the material\'s own values (they are the parent\'s)')
    rc = port('--op', f'file.open {f}', '--select', 'Cube', '--click-label', 'tab:Material', '--click-label', 'override:Wear', '--op', f'file.save_as {D}/p1.bee',
              '--op', 'edit.undo', '--op', f'file.save_as {D}/p2.bee', '--op', 'edit.redo', '--op', f'file.save_as {D}/p3.bee')
    ok = rc == 0 and all(os.path.exists(f'{D}/p{k}.bee') for k in '123')
    check(ok and graphs(f'{D}/p1.bee') != graphs(f) and graphs(f'{D}/p2.bee') == graphs(f) and graphs(f'{D}/p3.bee') == graphs(f'{D}/p1.bee'),
          'Wear overridden by a click changed the instance, the undo took it back, the redo put it again')


def s_fuzz():
    print('-- fuzz: random graph commands with bad words and numbers, previews, nodeval of everything (no panics, no hangs) --')
    r = random.Random(SEED + 6)
    bad = ['nan', 'inf', '-inf', '1e30', '-1e30', '99999', '-5', '', 'x', '0x10', '3.5', '48', '49', '65536', '4294967297']
    ids = ['material.node', 'material.link', 'material.node_set', 'material.socket', 'material.node_delete', 'material.node_move', 'material.node_name',
           'material.param', 'material.param_reset', 'material.instance', 'material.make_function', 'material.nodes_clear', 'material.function_new']
    worst = 0
    for s in range(RUNS):
        ops, mats = session(r, 40)
        for _ in range(40):
            i = r.choice(ids)
            words = [r.choice(mats + ['Nope', ''])] + [r.choice(bad + TYPES[:5] + [str(r.randrange(0, 50))]) for _ in range(r.randrange(0, 7))]
            ops.insert(r.randrange(len(ops) + 1), (i, ' '.join(words)))
        ops += [('view.shading_material', ''), ('edit.undo', ''), ('edit.undo', ''), ('edit.redo', '')]
        qf = f'{T}/fq.txt'
        open(qf, 'w').write(''.join(f'{m} {n} {k} 0.5 -0.25 1.5 0.3 0.7\n' for m in mats for n in range(0, 50) for k in (0, 3, 7, 31)))
        import time
        t0 = time.time()
        rc = port(*opsargs(ops), '--dump-nodeval', f'{qf};{T}/fa.txt', timeout=300)
        worst = max(worst, time.time() - t0)
        check(rc == 0, f'fuzz session {s}: {len(ops)} commands, previews and {4 * 50 * len(mats)} nodevals ran ({rc})')
    print(f'    (the slowest session: {worst:.1f} s)')


EXTRA = {'image': 'oracle_tex 0.7 0 0', 'textureparam': 'T oracle_tex 0.5 0 2', 'triplanar': '1 0.9 4 0', 'fncall': 'Fn', 'scalarparam': 'S 0.3', 'vectorparam': 'V 0.1 0.6 0.3',
         'math': '8', 'vmath': '12', 'mix': '5', 'voronoi': '6 1 0', 'wave': '5 1.5 0 1', 'gradient': '1 2 0', 'brick': '6 0.05 0.5', 'checker': '6', 'noise': '5 4 0.6',
         'blackbody': '3000', 'bump': '2 0.05', 'normalmap': '1 0', 'hsv': '0.3 1.2 1 1', 'gamma': '0.5', 'mapping': '30', 'panner': '0.5 0.25', 'rotator': '0.5 0.5 1', 'fresnel': '3 0.1'}


def spheres(path, types, keep_view=False, turned=False):
    """A sphere a node type, each graph: UV, position and noise into the node,
    the node into the base colour (bump and normal map: the normal), noise
    into roughness. A BeeScript builds it."""
    L = ['delete("Cube")' if keep_view else 'n = count()\nfor i in 0..n { delete(name(0)) }', f'op("image.load", "{TEX}")', 'op("material.function_new", "Fn")',
         'op("material.node", "Fn noise 6 3 0.5")', 'op("material.link", "Fn 1 3 1 0")', 'op("material.link", "Fn 3 2 1 0")']
    for i, t in enumerate(types):
        x, z = (i % 7) * 1.25 - 3.75, (i // 7) * 1.25 - 3.1
        m = f'M{i}'
        shape = ['scale(o, 0.6, 0.45, 0.55)', f'rotate(o, {i * 17 % 90}, 30, 0)'] if turned else ['scale(o, 0.55, 0.55, 0.55)']
        L += [f'o = add("sphere", "S{i}", {x}, 0, {z})'] + shape + [ f'op("material.new", "{m}")', f'op("material.node", "{m} texcoord 3 3")',
              f'op("material.node", "{m} position")', f'op("material.node", "{m} noise 4 3 0.5")', f'op("material.node", "{m} {t} {EXTRA.get(t, "")}")']
        for k, src in ((1, 3), (2, 2), (3, 1)):
            L.append(f'op("material.link", "{m} {src} 4 {k} 0")')
        if t in ('bump', 'normalmap'):
            L += [f'op("material.socket", "{m} normal 4")', f'op("material.socket", "{m} base 3")']
        else:
            L += [f'op("material.socket", "{m} base 4")', f'op("material.socket", "{m} roughness 3")']
    L.append(f'op("file.save", "{path}")')
    script('\n'.join(L))


def render_diff(a, b):
    from PIL import Image
    A = Image.open(a).convert('RGB')
    B = Image.open(b).convert('RGB')
    if A.size != B.size:
        return 1e9, 1e9
    w, h = A.size
    pa, pb = A.load(), B.load()
    tot = 0
    blocks = {}
    for y in range(h):
        for x in range(w):
            for c in range(3):
                u, v = pa[x, y][c], pb[x, y][c]
                tot += abs(u - v)
                e = blocks.setdefault((x // 8, y // 8, c), [0, 0])
                e[0] += u - v
                e[1] += 1
    return tot / (w * h * 3), max(abs(e[0]) / e[1] for e in blocks.values())


def s_render():
    print('-- path-traced renders of a sphere per node type: the window\'s F12 within the noise between two BeeScript renders --')
    D = f'{T}/render'
    os.makedirs(D, exist_ok=True)
    f = f'{D}/all.bee'
    # (turned and squashed: every real scene's objects are; a graph's base colour
    # below zero (Position) takes the tracer's lobe weights to their fallback)
    spheres(f, [t for t in TYPES if t != 'triplanar'], keep_view=True, turned=True)
    W, H, SPP = 320, 180, 64
    script(f'op("file.open", "{f}")\nop("render.device", "cpu")\nrender("{D}/o1.png", {W}, {H}, {SPP}, 0)\nrender("{D}/o2.png", {W}, {H}, {SPP}, 0)')
    port('--key', 'enter', '--type', f'file.open {f}', '--key', 'enter', '--type', 'render.device cpu', '--key', 'enter', '--type', f'render.settings {W} {H} {SPP}', '--key', 'enter',
         '--type', 'render.denoise', '--key', 'enter', '--key', 'esc', '--move', '615,360', '--key', 'f12', '--render-wait', '--key', 'enter', '--type', f'render.save {D}/z.png', '--key', 'enter')
    if not all(os.path.exists(f'{D}/{x}.png') for x in ('o1', 'o2', 'z')):
        check(False, 'the BeeScript and the window rendered')
        return
    noise, nb = render_diff(f'{D}/o1.png', f'{D}/o2.png')
    m, b = render_diff(f'{D}/o1.png', f'{D}/z.png')
    check(noise > 0 and m <= noise * 1.25 and b <= max(nb * 2, 2), f'the render: mean {m:.3f}, worst 8x8 block {b:.2f} /255 (two BeeScript renders: {noise:.3f}, {nb:.2f})')
    # one turned, squashed sphere coloured by its position (below zero on one side:
    # the tracer's lobe weights at their fallback)
    t = f'{D}/pos.bee'
    script('\n'.join(['delete("Cube")', 'o = add("sphere", "S", 0, 0.5, 0)', 'scale(o, 1.2, 0.7, 1.0)', 'rotate(o, 40, 30, 0)', 'op("material.new", "M")',
                     'op("material.node", "M position")', 'op("material.socket", "M base 1")', f'op("file.save", "{t}")']))
    W, H, SPP = 160, 90, 256
    script(f'op("file.open", "{t}")\nop("render.device", "cpu")\nrender("{D}/q1.png", {W}, {H}, {SPP}, 0)\nrender("{D}/q2.png", {W}, {H}, {SPP}, 0)')
    port('--key', 'enter', '--type', f'file.open {t}', '--key', 'enter', '--type', 'render.device cpu', '--key', 'enter', '--type', f'render.settings {W} {H} {SPP}', '--key', 'enter',
         '--type', 'render.denoise', '--key', 'enter', '--key', 'esc', '--move', '615,360', '--key', 'f12', '--render-wait', '--key', 'enter', '--type', f'render.save {D}/qz.png', '--key', 'enter')
    if all(os.path.exists(f'{D}/{x}.png') for x in ('q1', 'q2', 'qz')):
        noise, nb = render_diff(f'{D}/q1.png', f'{D}/q2.png')
        m, b = render_diff(f'{D}/q1.png', f'{D}/qz.png')
        check(noise > 0 and m <= noise * 1.25 and b <= max(nb * 2, 2), f'a turned, squashed sphere coloured by Position: mean {m:.3f}, worst block {b:.2f} (two BeeScript renders: {noise:.3f}, {nb:.2f})')
    else:
        check(False, 'the BeeScript and the window rendered the Position sphere')
    # the triplanar sphere alone: drawn
    t = f'{D}/tri.bee'
    spheres(t, ['triplanar'], keep_view=True)
    rc = port('--op', f'file.open {t}', '--op', 'view.shading_material', '--op', 'view.shading_rendered', '--live-wait')
    check(rc == 0, 'a Triplanar sample in Material Preview and Rendered: drawn, no stop')


def s_preview():
    print('-- Material Preview of a sphere per node type, against the same spheres with their graphs cleared --')
    from PIL import Image
    D = f'{T}/preview'
    os.makedirs(D, exist_ok=True)
    types = [t for t in TYPES if t != 'triplanar']
    spheres(f'{D}/g.bee', types, turned=True)  # (turned, squashed: the cofactor matters)
    # the control: the same spheres, their graphs cleared
    script(f'op("file.open", "{D}/g.bee")\n' + '\n'.join(f'op("material.nodes_clear", "M{i}")' for i in range(len(types))) + f'\nop("file.save", "{D}/p.bee")')
    rcs = []
    for k in ('g', 'p'):
        rcs.append(port('--move', '600,300', '--op', 'area.maximize', '--op', f'file.open {D}/{k}.bee', '--op', 'view.shading_material', shot=f'{D}/z_{k}.ppm'))
    check(rcs == [0, 0] and all(os.path.exists(f'{D}/z_{k}.ppm') for k in 'gp'), f'both drawn ({rcs})')
    if not all(os.path.exists(f'{D}/z_{k}.ppm') for k in 'gp'):
        return
    ga = Image.open(f'{D}/z_g.ppm').convert('RGB')
    pa = Image.open(f'{D}/z_p.ppm').convert('RGB')
    w, h = ga.size
    gp, pp = ga.load(), pa.load()
    shaded = sum(1 for y in range(82, min(h, 774)) for x in range(2, min(w, 1278)) if gp[x, y] != pp[x, y])
    plain = sum(1 for y in range(82, min(h, 774)) for x in range(2, min(w, 1278)) if min(pp[x, y]) > 120)
    check(plain > 10000, f'plain spheres drawn: {plain} light grey pixels')
    check(shaded > 10000, f'the graphs shade the spheres: {shaded} pixels apart from the control')
    c = ga.crop((2, 82, min(w, 1278), min(h, 774)))
    cols = len({c.getpixel((x, y)) for y in range(c.size[1]) for x in range(c.size[0])})
    check(cols > 1000, f'{cols} colours in the graph-shaded view')


def s_bytes():
    print(f'-- random sessions: every graph command, the same MATS and MGRF bytes both ways (seed {SEED}) --')
    r = random.Random(SEED)
    same = 0
    for s in range(RUNS):
        ops, _ = session(r)
        o, z = run_both(ops, f'b{s}')
        if not (os.path.exists(o) and os.path.exists(z)):
            check(False, f'session {s}: both files saved ({os.path.exists(o)}, {os.path.exists(z)})')
            continue
        (ma, ga), (mb, gb) = graphs(o), graphs(z)
        ok, note = same_session(ops, o, z, f'b{s}')
        nmf = sum(1 for i, a in ops if i == 'material.make_function')
        if not ok:
            check(False, f'session {s}: {note or "the same graphs"}')
            open(f'{T}/b{s}.ops', 'w').write(opsscript(ops, frames=False))
            print(f'    (its commands: {T}/b{s}.ops)')
        else:
            same += 1
            check(len(ga) > 1000, f'session {s}: {len(ops)} commands ({nmf} make_function), MATS {len(ma)} and MGRF {len(gb)} bytes the same{note}')
    return same


# ---- evaluation ------------------------------------------------------------------------

FB = '''fn fb(x) {
  if x != x { return "nan" }
  if x == 0 { return "0 0" }
  if x > 1e38 { return "inf" }
  if x < -1e38 { return "-inf" }
  e = 0
  s = 1
  if x < 0 { s = -1
    x = -x }
  while x >= 16777216 { x = x / 2
    e = e + 1 }
  while x < 8388608 { x = x * 2
    e = e - 1 }
  return "" + (s * x) + " " + e
}
'''


def fbits(s):
    """The BeeScript's fb() text as float bits (None: none)."""
    s = s.strip()
    if s == 'nan':
        return 'nan'
    if s in ('inf', '-inf'):
        return s
    m, e = s.split()
    v = float(m) * 2.0 ** int(e)
    return struct.unpack('<I', struct.pack('<f', v))[0]


def pbits(s):
    s = s.strip()
    if s == 'none':
        return None
    b = int(s, 16)
    f = struct.unpack('<f', struct.pack('<I', b))[0]
    if f != f:
        return 'nan'
    if f in (float('inf'), float('-inf')):
        return 'inf' if f > 0 else '-inf'
    if f == 0:
        return 0
    return b


def node_counts(path):
    """Each material's name and nodes (type, p0) from a file."""
    mats, g = graphs(path)
    n = struct.unpack_from('<I', mats)[0]
    names = [mats[4 + k * 128:4 + k * 128 + 32].split(b'\0')[0].decode() for k in range(n)]
    counts = {}
    o, k = 12, 0
    nm = struct.unpack_from('<I', g, 8)[0] if g and len(g) >= 12 else 0
    while k < nm and k < n and o + 4 <= len(g):
        nn = struct.unpack_from('<I', g, o)[0]
        if nn > 48 or o + 4 + 32 + nn * 72 + 480 > len(g):
            break  # (damaged: the readers stop here too)
        counts[names[k]] = [(struct.unpack_from('<I', g, o + 36 + i * 72)[0], struct.unpack_from('<f', g, o + 36 + i * 72 + 52)[0]) for i in range(nn)]
        o += 4 + 32 + nn * 72 + 480
        k += 1
    return names, counts


def written(t, p0):
    """The outputs a node writes (a link to another output reads zero)."""
    img = p0 == p0 and 1 <= p0 < 2  # (the one image the tests load)
    if t in (10, 11, 12, 13, 22, 23, 24):
        return (0, 1, 2, 3)
    if t == 19:
        op = int(p0) if p0 == p0 and abs(p0) < 1e9 else -1
        return (0, 1, 2, 3) if 0 <= op <= 19 and op not in (10, 13, 14) else (0,)
    if t in (20, 42):
        return (0, 1, 2)
    if t in (25, 32, 33, 34):
        return (0, 1)
    if t == 35:
        return (0, 1) if img else (0,)
    if t in (1, 39):
        return (0, 1, 2, 3, 4) if img else (0,)
    return (0,)


def eval_compare(bee, r, label, pts=4, ks=None, nodes_of=None):
    """nodeval of every node of every material at random points: a BeeScript's
    against the command line's (--dump-nodeval), on the same file. The nodes
    asked about are those there after reading the file back (graph_check
    clears a graph that does not make sense); each answer carries its query's
    number, so a query the BeeScript cannot answer is named, not lost."""
    kept = nodes_of
    if kept is None:
        kept = f'{T}/kept.bee'
        if os.path.exists(kept):
            os.remove(kept)
        script(f'op("file.open", "{bee}")\nop("file.save", "{kept}")')
    names, counts = node_counts(kept)
    _, written_counts = node_counts(bee)
    cleared = [m for m in names if written_counts.get(m) and not counts.get(m)]
    P = [(round(r.uniform(-3, 3), 3), round(r.uniform(-3, 3), 3), round(r.uniform(-3, 3), 3), round(r.uniform(-1, 2), 3), round(r.uniform(-1, 2), 3)) for _ in range(pts)]
    P[0] = (0.25, -1.5, 0.75, 0.125, 0.8)
    qs = []
    for m in names:
        for nd, (t, p0) in enumerate(counts.get(m, [])[:48], 1):
            for k in (ks or range(0, 32)):
                if k // 4 not in written(t, p0):
                    continue
                for p in P:
                    qs.append((m, nd, k, p))
    # (the graphs cleared on reading: the command line must clear them too)
    for m in cleared:
        qs.append((m, 1, 0, P[0]))
    if not qs:
        return 0, 0
    want = [None] * len(qs)
    missing = []
    pos = 0
    while pos < len(qs):
        part = range(pos, min(pos + 600, len(qs)))
        code = FB + f'op("file.open", "{bee}")\n' + '\n'.join(f'print("{i} " + fb(nodeval("{qs[i][0]}", {qs[i][1]}, {qs[i][2]}, {", ".join(str(x) for x in qs[i][3])})))' for i in part)
        out = script(code)
        for l in out.split('\n'):
            mm = re.match(r'^(\d+) (-?\d+(\.\d+)? -?\d+|nan|-?inf)$', l.strip())
            if mm and int(mm.group(1)) in part:
                want[int(mm.group(1))] = fbits(mm.group(2))
        gone = [i for i in part if want[i] is None]
        if not gone:
            pos = part[-1] + 1
            continue
        err = next((l for l in out.split('\n') if l.startswith('error')), out[-200:])
        missing.append((gone[0], err.strip()))
        pos = gone[0] + 1  # (the script stops at its error: on from the next one)
    qf = f'{T}/q.txt'
    open(qf, 'w').write(''.join(f'{m} {nd} {k} {p[0]} {p[1]} {p[2]} {p[3]} {p[4]}\n' for m, nd, k, p in qs))
    if os.path.exists(f'{T}/a.txt'):
        os.remove(f'{T}/a.txt')
    port('--op', f'file.open {bee}', '--dump-nodeval', f'{qf};{T}/a.txt')
    have = [pbits(x) for x in open(f'{T}/a.txt')] if os.path.exists(f'{T}/a.txt') else []
    if len(have) != len(qs):
        check(False, f'{label}: the command line answered {len(have)} of {len(qs)}')
        return 0, len(qs)
    # the BeeScript's "no such node" for a graph cleared reading the file: the command line's none
    known = [(i, e) for i, e in missing if qs[i][0] in cleared and 'no such node' in e]
    for i, e in known:
        want[i] = have[i] if have[i] is None else 'cleared'
    if cleared:
        check(all(have[i] is None for i, _ in known) and len(known) == len(cleared),
              f'{label}: {", ".join(cleared)}: a graph written with a link to a later node and cleared reading it back (graph_check): both ways')
    for i, e in missing:
        if (i, e) not in known:
            check(False, f'{label}: the BeeScript did not answer {qs[i]}: {e}')
    skip = {i for i, _ in missing}
    bad = [(qs[i], want[i], have[i]) for i in range(len(qs)) if i not in skip and want[i] != have[i]]
    nf = [qs[i] for i in range(len(qs)) if have[i] in ('nan', 'inf', '-inf')]
    if nf:
        print(f'    {len(nf)} outputs not finite, as {nf[0]}')
    tname = lambda q: TYPES[counts[q[0]][q[1] - 1][0] - 1] if q[0] in counts and q[1] <= len(counts[q[0]]) and 0 < counts[q[0]][q[1] - 1][0] <= 42 else '?'
    by = {}
    for q, w, h in bad:
        by.setdefault(tname(q), []).append((q, w, h))
    for t, l in by.items():
        q, w, h = l[0]
        print(f'    {t}: {len(l)} apart, as {q}: BeeScript {w if isinstance(w, str) else hex(w)}, command line {h if isinstance(h, str) or h is None else hex(h)}')
    return len(qs) - len(bad) - len(skip), len(qs) - len(skip)


def s_eval():
    print('-- every node\'s outputs at random points: nodeval the same bits both ways --')
    r = random.Random(SEED + 1)
    tot_ok = tot = 0
    nz = 0
    for s in range(max(2, RUNS // 2)):
        ops, _ = session(r, 90, out0=True)
        o = f'{T}/e{s}_o.bee'
        open(f'{T}/e{s}.ops', 'w').write(repr(ops))
        script(opsscript(ops + [('file.save', o)]))
        if not os.path.exists(o):
            check(False, f'eval session {s}: the BeeScript saved')
            continue
        check(not unreadable(o), f'eval session {s}: every graph saved reads back (no loop left by make_function)')
        ok, n = eval_compare(o, r, f'eval session {s}')
        tot_ok += ok
        tot += n
        check(n > 0 and ok == n, f'eval session {s}: {ok} of {n} node outputs the same bits both ways')
    # every type alone, its outputs, fed by varying inputs
    ops = [('image.load', TEX), ('material.function_new', 'Fn'), ('material.new', 'V')]
    feed = [('material.node', 'V texcoord 2.5 3.5 0.25 -0.125'), ('material.node', 'V position'), ('material.node', 'V noise 3 3 0.5')]
    ops += feed
    nodes = 3
    for t in TYPES:
        extra = {'image': 'oracle_tex 0.7 1 2', 'textureparam': 'T oracle_tex 1.5 0 1', 'triplanar': '1 0.9 4 1', 'fncall': 'Fn', 'scalarparam': 'S 0.3', 'vectorparam': 'V 0.1 0.2 0.3', 'math': '23', 'vmath': '15', 'mix': '9', 'voronoi': '3 0.7 2', 'wave': '3 1.5 1 2', 'gradient': '3 1.25 0.1'}.get(t, '')
        ops.append(('material.node', f'V {t} {extra}'.strip()))
        nodes += 1
        for i in (1, 2, 3):
            src = 1 + (nodes + i) % 3
            ops.append(('material.link', f'V {src} {nodes} {i} {i % 2 if src < 3 else 0}'))
    ops.append(('file.save', f'{T}/types_o.bee'))
    script(opsscript(ops))
    ok, n = eval_compare(f'{T}/types_o.bee', r, 'every type', pts=6)
    check(n > 0 and ok == n, f'every one of the 42 types, linked: {ok} of {n} outputs the same bits both ways')


def s_ops():
    print('-- every operation and mode of every node (math 0-32, vector math 0-21, mix 0-11, ...): bit for bit both ways --')
    feed = ['texcoord 2.5 3.5 0.25 -0.125', 'position', 'noise 3 3 0.5', 'constant 0.37', 'constant -1.25', 'constant 2.75', 'position 1', 'normal', 'camera', 'vcolor']
    groups = []

    def group(name, nodes):
        groups.append((name, nodes))
    group('math', [(f'math {op}', ((a, 0), (b, 0), (c, 0))) for op in range(33) for a, b, c in ((4, 6, 5), (5, 4, 6), (6, 5, 4), (3, 4, 6), (1, 2, 3))])
    group('vmath', [(f'vmath {op}', ((a, 0), (b, 0), (c, 0))) for op in range(-1, 22) for a, b, c in ((3, 2, 4), (1, 7, 6), (2, 9, 5))])
    group('mix', [(f'mix {mode}', ((4, 0), (3, 0), (2, 0))) for mode in range(-1, 13)] + [(f'mix {mode}', ((3, 0), (1, 0), (2, 0))) for mode in range(12)])
    group('patterns', [(f'gradient {ax} 1.25 0.1', ()) for ax in range(-1, 6)] + [(f'voronoi {sc} {r} {md}', ((src, 0),)) for md in range(4) for sc, r in ((5, 1), (2, 0.3)) for src in (2, 3)] +
          [(f'wave {sc} {d} {md} {ax}', ((src, 0),)) for md in (0, 1) for ax in (0, 1, 2, 5) for sc, d in ((4, 0), (3, 1.5)) for src in (2, 3)] +
          [('whitenoise', ()), ('whitenoise', ((3, 0),)), ('brick 4 0.03 0.5', ()), ('brick 7.5 0.1 0.25', ((2, 0), (4, 0), (5, 0))), ('checker 2', ()), ('checker 5.5', ((3, 0), (1, 0))),
           ('noise 1.5 8 0.7', ()), ('noise 9 12 1', ((3, 0),)), ('noise 0.25 0 0.2', ())])
    group('colour', [(f'hsv {h} {sa} {v} {f}', ((src, 0),)) for h, sa, v, f in ((0.2, 1.3, 0.7, 1), (0.75, 0.5, 1.5, 0.5), (0, 0, 1, 1)) for src in (3, 1, 2)] +
          [(f'{t} {v}', ((src, 0),)) for t, v in (('invert', 0.7), ('brightcon', '0.2 0.4'), ('desaturate', 0.6), ('gamma', 2.2), ('gamma', 0.45)) for src in (3, 2)] +
          [(f'blackbody {k}', ()) for k in (500, 800, 1500, 1900, 2500, 6500, 6600, 6700, 12000, 40000)] + [('fresnel 5 0.04', ()), ('fresnel 2 0.2', ((3, 0),)), ('fresnel 1.5 0', ((2, 0),))])
    group('vectors', [('separate', ((3, 0),)), ('combine', ((4, 0), (5, 0), (6, 0))), ('mapping 33', ()), ('mapping -120', ((2, 0), (3, 0), (1, 0))), ('panner 0.5 -0.25', ((0, 0), (4, 0))),
                      ('panner 0.5 -0.25', ((2, 0), (6, 0))), ('rotator 0.5 0.5 0.25', ((0, 0), (4, 0))), ('rotator 0.3 -0.2 2', ((1, 0), (6, 0))), ('reroute', ((3, 0),)), ('time 3', ()),
                      ('scalarparam S 0.3', ()), ('vectorparam V 0.1 0.2 0.3', ()), ('triplanar 1 0.9 4 0', ()), ('triplanar 1 0.5 1 1', ()), ('textureparam T oracle_tex 1.5 1 2', ((1, 0),)),
                      ('image oracle_tex 0.7 2 0', ((2, 0),)), ('bump 0.5 0.02', ((3, 0),)), ('normalmap 0.75 1', ((3, 0),)), ('texcoord 1 2 3 4', ())])
    r = random.Random(SEED + 7)
    for name, nodes in groups:
        # (48 nodes a material: the rest in more materials)
        mats, cur = [], []
        for nd in nodes:
            cur.append(nd)
            if len(cur) == 48 - len(feed):
                mats.append(cur)
                cur = []
        if cur:
            mats.append(cur)
        ok = n = 0
        for part, nds in enumerate(mats):
            ops = [('image.load', TEX), ('material.new', 'O')] + [('material.node', f'O {f}') for f in feed]
            k = len(feed)
            for spec, links in nds:
                ops.append(('material.node', f'O {spec}'))
                k += 1
                for i, (src, out) in enumerate(links, 1):
                    if src:
                        ops.append(('material.link', f'O {src} {k} {i} {out}'))
            path = f'{T}/ops_{name}_{part}.bee'
            script(opsscript(ops + [('file.save', path)]))
            a, b = eval_compare(path, r, f'{name} {part}', pts=4)
            ok += a
            n += b
        check(n > 0 and ok == n, f'{name}: {len(nodes)} nodes, {ok} of {n} outputs the same bits both ways')


# ---- make_function, by hand -------------------------------------------------------------

def s_makefn():
    print('-- material.make_function: the function and its call, the same bytes both ways; loops and a full graph refused --')
    base = [('material.new', 'M'), ('material.node', 'M texcoord 2 3'), ('material.node', 'M noise 4 3 0.5'), ('material.node', 'M math 2'),
            ('material.node', 'M color'), ('material.node', 'M mix 1'), ('material.node', 'M scalarparam Wear 0.25'), ('material.node', 'M invert 0.5'),
            ('material.link', 'M 1 2 1 0'), ('material.link', 'M 2 3 1 0'), ('material.link', 'M 6 3 2 0'), ('material.link', 'M 3 5 1 0'),
            ('material.link', 'M 4 5 2 0'), ('material.link', 'M 2 5 3 0'), ('material.link', 'M 5 7 1 0'), ('material.socket', 'M base 7'),
            ('material.socket', 'M roughness 3 0'), ('material.node_move', 'M 2 100 40'), ('material.node_move', 'M 3 260 -20'), ('material.node_move', 'M 5 420 77')]
    base += [('material.node', 'M math 1'), ('material.link', 'M 1 8 1 0'), ('material.link', 'M 4 8 2 0'), ('material.link', 'M 6 8 3 0')]
    cases = ['M 3 8', 'M 8', 'M 1 3 8', 'M 2 3', 'M 3 5', 'M 2 3 5', 'M 5 7', 'M 1 2 3 4 5 6 7', 'M 7', 'M 2x 3', 'M', 'M 0 99', 'Nope 1', 'M 4 6', 'M 1 4 6',
             'M 3 3 3', 'M 48 2']
    for c in cases:
        ops = base + [('material.make_function', c)]
        o, z = run_both(ops, 'mf')
        (ma, ga), (mb, gb) = graphs(o), graphs(z)
        lg = [l for l in portlog().split('\n') if 'function' in l]
        ok, note = same_session(ops, o, z, f'mf {c}')
        check(ok and ma is not None and not unreadable(z), f'make_function {c}: the same bytes both ways, every graph reads back{note} ({first_diff(ga, gb)}){" - " + lg[-1].strip() if lg else ""}')
    # nodes that would make a loop with the rest: the call would feed node 2 and node
    # 2 the call. Refused: nothing changes, it says so
    lp = [('material.new', 'L'), ('material.node', 'L position'), ('material.node', 'L math 2'), ('material.node', 'L math 0'),
          ('material.link', 'L 1 2 1 0'), ('material.link', 'L 2 3 1 0'), ('material.link', 'L 1 3 2 0'), ('material.socket', 'L base 3')]
    o, z = run_both(lp + [('material.make_function', 'L 1 3')], 'mloop')
    said = refused() == ['L 1 3']
    o0, z0 = run_both(lp, 'mloop0')
    check(said and graphs(z) == graphs(z0) and graphs(o) == graphs(o0) == graphs(z0), 'make_function that loops: refused both ways, it says so, and nothing changes')
    check(not unreadable(z), 'make_function that loops: the file reads back whole')
    # (no undo step: one undo takes the command before it back)
    port(*opsargs(lp + [('material.make_function', 'L 1 3'), ('edit.undo', ''), ('file.save', f'{T}/mloop_u.bee')]))
    port(*opsargs(lp[:-1] + [('file.save', f'{T}/mloop_p.bee')]))
    check(graphs(f'{T}/mloop_u.bee') == graphs(f'{T}/mloop_p.bee'), 'make_function that loops: no undo step (one undo takes the pin before it back)')
    # a full graph: no room for the call: checked first
    full = [('material.new', 'M')] + [('material.node', 'M constant 0.5')] * 48 + [('material.link', 'M 1 2 1 0')]
    o, z = run_both(full + [('material.make_function', 'M 2')], 'mfull')
    said = 'make_function: up to 3' in portlog()
    o0, z0 = run_both(full, 'mfull0')
    (ma, ga), (mb, gb) = graphs(o), graphs(z)
    check(graphs(z0) == (mb, gb) and graphs(o0) == graphs(o) == graphs(z0) and b'M_fn' not in mb and said,
          'make_function on a full graph: nothing changes both ways, and it says so')
    # in a chain: functions of functions, evaluated
    ops = base + [('material.make_function', 'M 2 3'), ('material.make_function', 'M 3 4'), ('material.node', 'M fncall M_fn'), ('material.link', 'M 1 8 1 0'),
                  ('material.make_function', 'M 8 1')]
    ops += [('material.node', 'M constant 0.5')] * 30 + [('material.make_function', 'M 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32')]
    o, z = run_both(ops, 'mf2')
    (ma, ga), (mb, gb) = graphs(o), graphs(z)
    check(ma == mb and ga == gb, f'make_function in a chain, then of 32 nodes: the same bytes both ways ({first_diff(ga, gb)})')
    ok, n = eval_compare(o, random.Random(5), 'functions', pts=3, ks=(0, 3, 4, 7, 8, 11))
    check(n > 0 and ok == n, f'functions made from nodes evaluate the same both ways: {ok} of {n}')


def main():
    print(f'shnodes: {BIN}, sessions {RUNS}, seed {SEED}')
    for f in (s_bytes, s_files, s_undo, s_makefn, s_eval, s_ops, s_damage, s_window, s_render, s_preview, s_fuzz):
        if not ONLY or f.__name__ in ONLY:
            f()
    print(f'shnodes: fails {len(FAILS)}')
    for f in FAILS:
        print('  -', f)


try:
    main()
finally:
    import shutil
    if not os.environ.get('SH_KEEP'):
        shutil.rmtree(T, True)
sys.exit(1 if FAILS else 0)
