#!/usr/bin/env python3
"""BeeScript's material and node builtins (src/bs_mat.zig, src/bs_nodes.zig)
run by BeeModel (--eval and --run, a temp HOME and XDG_RUNTIME_DIR each):
each script ends cleanly (its output or one script error, exit 0 or 1, no
crash, panic or timeout), prints the same and saves the same scene through
--eval and --run, and every .bee file it saves reads back and survives
open -> save unchanged (materials, their graphs, node trees, what objects
wear); every builtin with each argument count and every argument swapped for
wrong types, bad names and edge values (NaN, infinities, huge, negative,
empty text); random call sequences; a run undone and redone (one step);
random garbage (no crash, no hang); memory over many runs.

    python3 tests/bs_mat.py BIN [random-runs=150] [seed]

BS_ONLY=scripts,args,random,corpus,undo,garbage,leak runs some sections.
"""
import concurrent.futures, os, random, re, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 150
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('BS_ONLY', '').split(',') if x]
JOBS = int(os.environ.get('BS_JOBS', '8'))
FAILS = []
T = tempfile.mkdtemp(prefix='beebsmat-', dir=os.environ.get('BS_TMP', '/tmp'))

MINE = ['material', 'matset', 'matget', 'assign', 'matof', 'instance', 'matparam',
        'node', 'link', 'nodeset', 'nodeinfo', 'nodeval', 'socket', 'gtree', 'gnode', 'glink', 'gset', 'ginfo']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(s):
    return not ONLY or s in ONLY


def xdg(h):
    """HOME and every XDG folder under h (the user's shell points them at the
    real ones: BeeModel autosaves into $XDG_CACHE_HOME)."""
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
    for v, sub in (('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state')):
        env[v] = os.path.join(h, sub)
    return env


def run(binary, args, timeout=120):
    """One run with a HOME and XDG_RUNTIME_DIR of its own: (rc, stdout, stderr)."""
    h = tempfile.mkdtemp(dir=T)
    env = xdg(h)
    env.pop('WAYLAND_DISPLAY', None)  # (never the user's real compositor)
    if args and args[0] == '--op':
        args = ['--shot', os.path.join(h, 'shot.ppm'), *args]  # (headless)
    try:
        r = subprocess.run([binary, *args], capture_output=True, timeout=timeout, env=env)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout', '')
    shutil.rmtree(h, True)
    return out


# ---- the scene in the .bee files (as tests/bscript.py reads them) ---------------------------

def scene(path):
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<II', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        me = meshes[mi] if typ == 0 and mi < len(meshes) else None
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], me))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL') or not b:
            continue
        if t == b'IMGD':
            b = images(b)
        rest.setdefault(t, []).append(b)
    return recs, rest


def images(d):
    """IMGD: each image's pixels, RGB (the PNG bytes need not be the same for
    the same pixels)."""
    from PIL import Image
    import io
    o, out = 0, b''
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        out += struct.pack('<I', ix) + Image.open(io.BytesIO(d[o + 8:o + 8 + n])).convert('RGB').tobytes()
        o += 8 + n
    return out


def scene_diff(pa, pb, skip=()):
    """'' when the two files hold the same scene (or neither exists), else why not.
    skip: chunks left out (undone: UIDS's next uid is not part of a step)."""
    ea, eb = os.path.exists(pa), os.path.exists(pb)
    if not ea and not eb:
        return ''
    if ea != eb:
        return f'a file is missing (first {ea}, second {eb})'
    (ra, xa), (rb, xb) = scene(pa), scene(pb)
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        if a != b:
            why.append(f'object {k}')
    for t in sorted((set(xa) | set(xb)) - set(skip)):
        ca, cb = xa.get(t, []), xb.get(t, [])
        if ca != cb:
            a, b = b''.join(ca), b''.join(cb)
            k = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
            why.append(f'{t.decode()} chunk ({len(a)} / {len(b)} bytes, from byte {k}: {a[k:k + 12].hex()} / {b[k:k + 12].hex()})')
    return '; '.join(why[:4])


def go(code, tag, timeout, mode):
    """The code run once (@OUT: where it saves): (rc, stdout, stderr), the file."""
    pb = f'{T}/{tag}.bee'
    cb = code.replace('@OUT', pb)
    if mode == '--run':
        fb = f'{T}/{tag}.bees'
        open(fb, 'w').write(cb)
        b = run(BIN, ['--run', fb], timeout)
        b = (b[0], b[1].replace(fb, '@S'), b[2])
    else:
        b = run(BIN, ['--eval', cb], timeout)
    return (b[0], b[1].replace(pb, '@OUT'), b[2]), pb


def crashed(b):
    """Why a run did not end as a program should (a result or one script error), or ''."""
    if b[0] is None:
        return 'timed out'
    if b[0] not in (0, 1) or 'panic' in b[1] + b[2] or 'reached unreachable' in b[2]:
        return f'crashed: rc {b[0]} {(b[1] + b[2])[-300:]!r}'
    return ''


def readback(pb, tag):
    """'' when the saved file reads back and open -> save gives the same scene, else why not."""
    try:
        scene(pb)
    except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
        return f'its .bee does not read back ({e})'
    p2 = f'{T}/{tag}_again.bee'
    r = run(BIN, ['--eval', f'op("file.open", "{pb}")\nop("file.save", "{p2}")'])
    if r[0] != 0:
        return f'open -> save failed: rc {r[0]} {(r[1] + r[2])[-200:]!r}'
    d = scene_diff(pb, p2)
    os.path.exists(p2) and os.unlink(p2)
    return f'open -> save changed it: {d}' if d else ''


def pair(code, tag, timeout=120, mode='--eval', again=True):
    """The code run by BeeModel (@OUT: where it saves): (fine?, why, its run).
    Fine: a clean end, a saved file when it ran to the end, and the file reads
    back (again: and open -> save keeps its scene)."""
    b, pb = go(code, tag, timeout, mode)
    why = []
    c = crashed(b)
    if c:
        why.append(c)
    elif os.path.exists(pb):
        r = readback(pb, tag) if again else ''
        if not again:
            try:
                scene(pb)
            except Exception as e:  # noqa: BLE001
                r = f'its .bee does not read back ({e})'
        if r:
            why.append(r)
    elif b[0] == 0 and '@OUT' in code:
        why.append('no file saved')
    if os.path.exists(pb):
        os.unlink(pb)
    return not why, '; '.join(why), b


def same(code, what, tag='s', **kw):
    ok, why, b = pair(code, tag, **kw)
    check(ok, what + ('' if ok else ': ' + why))
    return ok, b


def eval_and_run(code, what, tag):
    """--eval and --run: each clean, and the same output and scene from each."""
    b1, p1 = go(code, tag + 'e', 120, '--eval')
    b2, p2 = go(code, tag + 'r', 120, '--run')
    why = [f'{m}: {c}' for m, c in (('--eval', crashed(b1)), ('--run', crashed(b2))) if c]
    if not why:
        if (b1[0], b1[1]) != (b2[0], b2[1]):
            why.append(f'output\n         --eval {b1[:2]!r}\n         --run  {b2[:2]!r}')
        d = scene_diff(p1, p2)
        if d:
            why.append('scene: ' + d)
        elif os.path.exists(p1):
            r = readback(p1, tag)
            if r:
                why.append(r)
        elif b1[0] == 0 and '@OUT' in code:
            why.append('no file saved')
    for p in (p1, p2):
        os.path.exists(p) and os.unlink(p)
    check(not why, what + ': clean, the same through --eval and --run' + ('' if not why else ': ' + '; '.join(why)))


def png(path, w, h, f):
    """A small RGB PNG (f(x, y) -> (r, g, b))."""
    raw = b''.join(b'\0' + bytes(c for x in range(w) for c in f(x, y)) for y in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


TEX = os.path.join(T, 'tex.png')
png(TEX, 8, 8, lambda x, y: (x * 30, y * 30, (x ^ y) * 16))

# A scene to call the builtins on: a material with a small graph, a function,
# an instance, an image, a node tree.
PRE = f'''m = material("M")
n1 = node(m, "texcoord", 2, 2)
n2 = node(m, "checker", 6)
link(m, n1, n2, 1)
n3 = node(m, "vectorparam", "Tint", 0.8, 0.2, 0.1)
n4 = node(m, "mix", 2)
link(m, n2, n4, 2)
link(m, n3, n4, 3)
socket(m, "base", n4)
n5 = node(m, "scalarparam", "Wear", 0.3)
socket(m, "roughness", n5)
i = instance(m, "MI")
op("image.load", "{TEX}")
op("material.function_new", "Fn")
t = gtree("T")
g1 = gnode(t, "grid", 3, 3)
g2 = gnode(t, "transform")
glink(t, g1, g2, 1)
add("cube", "Box", 2, 0, 0)
'''


# ---- fixed scenarios -------------------------------------------------------------------------

SCRIPTS = [
    ('materials: made, found, named', '''m = material("M")
print(m, material("M"), material(""), material(""), material("M"))
print(material("a very long material name that goes on and on"), material("a very long material name that goes on and on"))
print(material("Ünïcödé näme with àccents and more"), matof("Cube"))'''),
    ('matset / matget: clamped, NaN and infinities, components', '''m = material("M")
print(matget(m, "roughness"), matget(m, "base", 0), matget(m, "base", 2), matget(m, "base", -1), matget(m, "base", 3), matget(m, "base", 1e30), matget(m, "roughness", 1), matget(m, "metallic", 2))
matset(m, "base", 0.2, 0.3, 0.4)
matset(m, "roughness", sqrt(-1))
matset(m, "ior", 1e30)
matset(m, "strength", -5)
matset(m, "metallic", 0.5, 0.7, 0.9)
matset(m, "emission", 2)
matset(m, "density", pow(10, 400))
matset(m, "alpha", -pow(10, 400))
for p in 0..1 { }
print(matget(m, "base", 0), matget(m, "base", 1), matget(m, "base", 2), matget(m, "roughness"), matget(m, "ior"), matget(m, "strength"))
print(matget(m, "metallic"), matget(m, "emission", 0), matget(m, "emission", 1), matget(m, "density"), matget(m, "alpha"))
matset(m, "blend", 2.7)
matset(m, "one_sided", 1)
matset(m, "clip", 0.25)
print(matget(m, "blend"), matget(m, "one_sided"), matget(m, "clip"), matget(m, "specular"), matget(m, "transmission"), matget(m, "clearcoat"), matget(m, "coat_roughness"))
op("file.save", "@OUT")'''),
    ('assign / matof', '''m = material("M")
print(matof("Cube"))
assign("Cube", m)
print(matof("Cube"))
assign("Cube", "")
print(matof("Cube"))
assign("Cube", m)
assign("Cube", nil)
print(matof("Cube"))
assign("Cube", m)
assign("Cube", 3)
print(matof("Cube"))
assign("Cube", m)
op("file.save", "@OUT")'''),
    ('nodes: a graph built, read back, evaluated', PRE + '''print(n1, n2, n3, n4, n5, i)
print(nodeinfo(m, 0, "count"), nodeinfo(m, 4, "type"), nodeinfo(m, 4, "link", 2), nodeinfo(m, 4, "link", 3), nodeinfo(m, 0, "socket", 0), nodeinfo(m, 0, "socket", 3))
print(nodeinfo(m, 0, "x"), nodeinfo(m, 0, "y"), nodeinfo(m, 1, "x"), nodeinfo(m, 2, "value", 1), nodeinfo(m, 3, "value", 3), nodeinfo(m, 4, "linkout", 2), nodeinfo(m, 0, "socketout", 0))
print(nodeinfo(m, 0, "type"), nodeinfo(m, 9, "type"), nodeinfo(m, -1, "type"), nodeinfo(m, 4, "link", 0), nodeinfo(m, 4, "link", 4), nodeinfo(m, 0, "socket", 13), nodeinfo(m, 0, "socket", -1), nodeinfo(m, 2, "value", 0), nodeinfo(m, 2, "value", 5))
for k in 0..12 { print(k, nodeval(m, 2, k, 0.1, 0.2, 0.3), nodeval(m, 4, k, 0.37, -0.5, 1.25, 0.2, 0.7), nodeval(m, 1, k, 1, 2, 3, 0.25, 0.75)) }
print(nodeval(m, 4, 0, sqrt(-1), 0, 0), nodeval(m, 4, 0, pow(10, 400), 0, 0), nodeval(m, 4, 31, 0, 0, 0), nodeval(m, 4, 32, 0, 0, 0), nodeval(m, 4, -1, 0, 0, 0))
print(matparam(m, "Tint"), matparam(m, "Wear"), matparam(i, "Tint"), matparam(i, "Wear"))
matparam(i, "Tint", 0.1, 0.2, 0.9)
matparam(i, "Wear", 0.8)
print(matparam(i, "Tint"), matparam(m, "Tint"), matparam(i, "Wear"), nodeval(i, 4, 0, 0.3, 0.3, 0.3), nodeval(m, 4, 0, 0.3, 0.3, 0.3))
matset(m, "metallic", 0.4)
print(matget(i, "metallic"), instance(m), instance(m), instance(i, "MI2"), matparam("MI2", "Wear"))
op("file.save", "@OUT")'''),
    ('nodes: every type, values, images and functions', f'''m = material("M")
op("image.load", "{TEX}")
op("material.function_new", "Fn")
k = 0
''' + '\n'.join(f'k = node(m, "{t}", 1, 2, 3, 4)' for t in
                ['noise', 'checker', 'gradient', 'mix', 'ramp', 'math', 'bump', 'normalmap', 'texcoord', 'position', 'normal', 'camera', 'vcolor',
                 'time', 'constant', 'color', 'fresnel', 'vmath', 'separate', 'combine', 'mapping', 'panner', 'rotator', 'voronoi', 'hsv',
                 'invert', 'brightcon', 'desaturate', 'gamma', 'blackbody', 'brick', 'wave', 'whitenoise', 'triplanar', 'reroute']) + '''
print(k, nodeinfo(m, 0, "count"))
m2 = material("Img")
print(node(m2, "image", "tex", 5, 6), node(m2, "image"), node(m2, "textureparam", "Tx", "tex", 9), node(m2, "textureparam", "tex"), node(m2, "fncall", "Fn", 2), node(m2, "fncall"))
print(node(m2, "scalarparam", 0.5, 0.25), node(m2, "vectorparam"), node(m2, "scalarparam", "a name longer than twenty-three characters", 1))
for q in 1..10 { print(q, nodeinfo(m2, q, "type"), nodeinfo(m2, q, "value", 1), nodeinfo(m2, q, "value", 2), nodeinfo(m2, q, "value", 3), nodeinfo(m2, q, "value", 4)) }
print(matparam(m2, "a name longer than twen"), matparam(m2, "Param 1"), matparam(m2, "Tx"), matparam(m2, "tex"))
op("file.save", "@OUT")
print(matparam(m2, "a name longer than twent"))'''),
    ('nodes: 48 at most, links that would loop, sockets', '''m = material("M")
for q in 0..48 { node(m, "constant", q) }
print(nodeinfo(m, 0, "count"), link(m, 1, 2, 1), link(m, 2, 3, 1), link(m, 47, 48, 1, 7), link(m, 30, 10, 2, 1), link(m, 48, 5, 3))
print(nodeinfo(m, 0, "count"), nodeinfo(m, 47, "link", 1), nodeinfo(m, 48, "linkout", 1), nodeinfo(m, 11, "link", 2), nodeinfo(m, 11, "linkout", 2))
for q in 1..49 { print(q, nodeinfo(m, q, "value", 1), nodeinfo(m, q, "link", 1), nodeinfo(m, q, "link", 2), nodeinfo(m, q, "link", 3)) }
socket(m, "mask", 48, 3)
socket(m, "normal", 2)
socket(m, "base", nil)
print(nodeinfo(m, 0, "socket", 12), nodeinfo(m, 0, "socketout", 12), nodeinfo(m, 0, "socket", 6), nodeinfo(m, 0, "socket", 0))
op("file.save", "@OUT")
link(m, 48, 47, 2)'''),
    ('nodes: the 49th', '''m = material("M")
for q in 0..48 { node(m, "constant", q) }
node(m, "constant")'''),
    ('names cut at 26 bytes', '''print(material("aaaaaaaaaaaaaaaaaaaaaaaaa"), gtree("aaaaaaaaaaaaaaaaaaaaaaaaaé"), instance("aaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
print(material("aaaaaaaaaaaaaaaaaaaaaaaaa"), instance("bbbbbbbbbbbbbbbbbbbbbbbbbb"), instance("bbbbbbbbbbbbbbbbbbbbbbbbbb"))
op("file.save", "@OUT")'''),
    ('nodes: a loop refused', '''m = material("M")
node(m, "math")
node(m, "math")
link(m, 1, 2, 1)
op("file.save", "@OUT")
link(m, 2, 1, 1)'''),
    ('nodeset: inputs and values, one and three numbers', '''m = material("M")
node(m, "math")
node(m, "color")
link(m, 1, 2, 1)
nodeset(m, 2, 1, 0.5)
nodeset(m, 1, 2, 0.1, 0.2)
nodeset(m, 1, 3, 0.1, 0.2, 0.3)
nodeset(m, 1, 4, 7)
nodeset(m, 1, 7, 1, 2, 3)
print(nodeinfo(m, 2, "link", 1), nodeinfo(m, 1, "value", 1), nodeinfo(m, 1, "value", 4), nodeval(m, 2, 0, 0, 0, 0))
op("file.save", "@OUT")
nodeset(m, 1, 8, 1)'''),
    ("the output node's place, a time node at a frame", '''m = material("M")
op("material.node_move", "M 0 120 -40")
k = node(m, "time")
op("material.node_move", "M 1 -300 75")
print(nodeinfo(m, 0, "x"), nodeinfo(m, 0, "y"), nodeinfo(m, 1, "x"), nodeinfo(m, 1, "y"))
frame(37)
print(nodeval(m, k, 0, 0, 0, 0), nodeval(m, k, 3, 0, 0, 0))
op("file.save", "@OUT")'''),
    ('geometry node trees', '''t = gtree("T")
print(t, gtree("T"), gtree(""), gtree(""), gtree("a long tree name that is long enough"), gtree("a long tree name that is long enough"))
a = gnode(t, "grid", 4, 4, 2, 2)
b = gnode(t, "transform", 1, 2, 3, 4)
c = gnode(t, "subdivide")
print(a, b, c, glink(t, a, b, 1), glink(t, b, c, 1, 0), gset(t, b, 4, 9), gset(t, b, 2, 1, 2, 3), gset(t, b, 3, 5))
print(ginfo(t, 0, "count"), ginfo(t, b, "type"), ginfo(t, c, "link", 1), ginfo(t, c, "output", 1), ginfo(t, b, "value", 1), ginfo(t, b, "value", 4), ginfo(t, b, "x"), ginfo(t, b, "y"))
print(ginfo(t, 0, "type"), ginfo(t, 9, "type"), ginfo(t, b, "link", 0), ginfo(t, b, "link", 4), ginfo(t, b, "value", 0), ginfo(t, b, "value", 5), ginfo(t, -1, "value", 1))
print(ginfo(t, b, "link", 2), ginfo(t, b, "link", 1))
op("file.save", "@OUT")
glink(t, c, a, 1)'''),
    ('geometry node trees: 48 nodes, 64 trees', '''t = gtree("T")
for q in 0..48 { gnode(t, "grid") }
print(ginfo(t, 0, "count"))
for q in 0..63 { gtree("X" + q) }
print(gtree("X0"), gtree("X62"))
op("file.save", "@OUT")
gtree("one too many")'''),
    ('a node tree full', '''t = gtree("T")
for q in 0..48 { gnode(t, "grid") }
gnode(t, "grid")'''),
]


def s_scripts():
    print('-- scenarios: clean, the same through --eval and --run, the files read back --')
    for k, (what, code) in enumerate(SCRIPTS):
        eval_and_run(code, what, f's{k}')
    # (material.zig: a name cut at 26 bytes inside a UTF-8 character loses the whole character)
    code = 'print(material("' + 'a' * 25 + 'é"), material("' + 'a' * 24 + 'é"))'
    _, _, b = pair(code, 'utf')
    check(b[1] == 'a' * 25 + ' ' + 'a' * 24 + 'é\n', f'a material name cut inside a UTF-8 character: the half character dropped ({b[1]!r})')


# ---- each builtin: argument counts, wrong types, bad names, edge values -------------------

# a valid call of each builtin (after PRE), at its most arguments
VALID = {
    'material': ['"M"'],
    'matset': ['m', '"base"', '0.2', '0.3', '0.4'],
    'matget': ['m', '"base"', '1'],
    'assign': ['"Box"', 'm'],
    'matof': ['"Cube"'],
    'instance': ['m', '"Z"'],
    'matparam': ['i', '"Tint"', '0.1', '0.2', '0.3', '0.4'],
    'node': ['m', '"noise"', '1', '2', '3', '4'],
    'link': ['m', '1', '4', '1', '0'],
    'nodeset': ['m', '4', '1', '0.1', '0.2', '0.3'],
    'nodeinfo': ['m', '4', '"link"', '2'],
    'nodeval': ['m', '4', '1', '0.1', '0.2', '0.3', '0.4', '0.5'],
    'socket': ['m', '"metallic"', '5', '0'],
    'gtree': ['"T"'],
    'gnode': ['t', '"grid"', '1', '2', '3', '4'],
    'glink': ['t', '1', '2', '1', '0'],
    'gset': ['t', '2', '1', '1', '2', '3'],
    'ginfo': ['t', '2', '"link"', '1'],
}
COUNTS = {nm: (int(mn), int(mx)) for nm, mn, mx in re.findall(r'\.name = "([a-z_0-9]+)", \.min = (\d+), \.max = (\d+)', open(os.path.join(ROOT, 'src', 'bs_table.zig')).read())}
EDGE = ['"M"', '"MI"', '"nope"', '""', 'nil', '0', '-1', '1', '2', '3', '4', '5', '6', '7', '8', '12', '13', '48', '49',
        '0.5', '-0.5', '1e30', '-1e30', '2147483648', '-2147483649', 'sqrt(-1)', 'pow(10, 400)', '-pow(10, 400)',
        '"base"', '"Cube"', '"Box"', '"T"', '"Tint"', '"Wear"', '"image"', '"count"', '"value"', '"socket"', '"output"', '"x"',
        '"linkout"', '"socketout"', '"grid"', '"tex"', '"tex.png"', '"Fn"', '"scalarparam"', '"textureparam"', '"fncall"', '"roughness"',
        '"mask"', '"ior"', '"blend"', '"clip"', '"BASE"', '"Count"', '"VALUE"', '"' + 'x' * 40 + '"']


def args_cases():
    cases = []
    for nm in MINE:
        mn, mx = COUNTS[nm]
        v = VALID[nm]
        assert len(v) == mx, nm
        for n in range(max(0, mn - 1), mx + 2):
            a = (v + ['1'])[:n]
            cases.append(f'{nm}({", ".join(a)})')
        # every argument swapped together with the last one (two wrong at once)
        for p in range(mx - 1):
            for e in ('"nope"', '-1', 'nil', '"x"'):
                a = list(v)
                a[p] = e
                a[-1] = '-1' if e != '-1' else '"nope"'
                cases.append(f'{nm}({", ".join(a)})')
        for n in range(mn, mx + 1):
            for p in range(n):
                for e in EDGE:
                    a = v[:n]
                    a[p] = e
                    cases.append(f'{nm}({", ".join(a)})')
    return sorted(set(cases))


def one_case(k_code):
    k, code = k_code
    full = PRE + f'print({code})\nop("file.save", "@OUT")'
    ok, why, _ = pair(full, f'a{k}')
    return ok, code, why


def s_args():
    print('-- each builtin: argument counts, wrong types, bad names, edge values --')
    cases = args_cases()
    bad = []
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for ok, code, why in ex.map(one_case, enumerate(cases)):
            if not ok:
                bad.append((code, why))
    for nm in MINE:
        mine = [c for c in cases if c.startswith(nm + '(')]
        nb = [b for b in bad if b[0].startswith(nm + '(')]
        check(not nb, f'{nm}: {len(mine)} calls, each clean, the files read back, open -> save the same' + ('' if not nb else f': {len(nb)} differ, e.g. {nb[0][0]}: {nb[0][1][:600]}'))


# ---- random call sequences ---------------------------------------------------------------

class Gen:
    def __init__(self, rng):
        self.r = rng

    def num(self):
        r = self.r
        return r.choice(['0', '1', '2', '3', '4', '5', '6', '7', '-1', '0.5', '0.25', '1.5', str(round(r.uniform(-3, 3), 3)),
                         str(r.randrange(0, 50)), 'sqrt(-1)', '1e30'])

    def bad(self):
        return self.r.random() < 0.01

    def node(self):
        return str(self.r.choice([0, 60]) if self.bad() else self.r.randrange(1, 7))

    def mat(self):
        return '"nope"' if self.bad() else self.r.choice(['m', 'm', 'm', 'i', '"M2"'])

    def call(self):
        r = self.r
        k = r.randrange(16)
        if k == 0:
            return f'material("{r.choice(["M", "M2", "M3", ""])}")'
        if k == 1:
            return f'matset({self.mat()}, "{r.choice(["base", "metallic", "roughness", "ior", "emission", "strength", "alpha", "blend"])}", ' + ', '.join(self.num() for _ in range(r.randrange(1, 4))) + ')'
        if k == 2:
            return f'matget({self.mat()}, "{r.choice(["base", "metallic", "roughness", "ior", "emission", "clip"])}", {self.num()})'
        if k == 3:
            return f'assign("{r.choice(["Cube", "Box", "Light" if self.bad() else "Cube"])}", {r.choice(["m", "i", chr(34) * 2, "nil"])})'
        if k == 4:
            return f'matof("{r.choice(["Cube", "Box"])}")'
        if k == 5:
            return f'node({self.mat()}, "{r.choice(["noise", "checker", "math", "mix", "color", "constant", "vmath", "scalarparam", "vectorparam", "texcoord", "position", "voronoi"])}"' + ''.join(', ' + self.num() for _ in range(r.randrange(0, 4))) + ')'
        if k == 6:
            a, b = sorted(r.sample(range(1, 7), 2))
            if self.bad():
                a, b = b, a
            return f'link({self.mat()}, {a}, {b}, {r.choice([1, 1, 2, 3])}' + (f', {r.choice([0, 0, 1, 2, 7])}' if r.random() < 0.4 else '') + ')'
        if k == 7:
            return f'nodeset({self.mat()}, {self.node()}, {r.randrange(1, 8)}, ' + ', '.join(self.num() for _ in range(r.randrange(1, 4))) + ')'
        if k == 8:
            return f'nodeinfo({self.mat()}, {self.node()}, "{r.choice(["count", "type", "link", "socket", "x", "y", "value", "linkout", "socketout"])}", {r.randrange(-1, 14)})'
        if k == 9:
            return f'nodeval({self.mat()}, {self.node()}, {r.randrange(-2, 34)}, ' + ', '.join(self.num() for _ in range(r.choice([3, 3, 5]))) + ')'
        if k == 10:
            return f'socket({self.mat()}, "{r.choice(["base", "metallic", "roughness", "emission", "normal", "mask", "ao"])}", {r.choice([self.node(), "nil"])})'
        if k == 11:
            return f'matparam({r.choice(["m", "i"])}, "{"nope" if self.bad() else r.choice(["Param 1", "Tint"])}"' + ''.join(', ' + self.num() for _ in range(r.randrange(0, 5))) + ')'
        if k == 12:
            return f'instance({self.mat()}' + (f', "I{r.randrange(4)}"' if r.random() < 0.5 else '') + ')'
        if k == 13:
            return f'gnode(t, "{r.choice(["grid", "transform", "subdivide", "join", "cube"])}"' + ''.join(', ' + self.num() for _ in range(r.randrange(0, 4))) + ')'
        if k == 14:
            a, b = sorted(r.sample(range(1, 5), 2))
            return r.choice([f'glink(t, {a}, {b}, {r.choice([1, 2, 3])})', f'gset(t, {r.randrange(1, 6)}, {r.randrange(1, 8)}, {self.num()})'])
        return f'ginfo(t, {r.randrange(0, 7)}, "{r.choice(["count", "type", "link", "output", "x", "y", "value"])}", {r.randrange(-1, 6)})'

    def program(self):
        lines = ['m = material("M")', 'material("M2")', 'for q in 0..6 { node(m, "' + self.r.choice(['noise', 'math', 'mix', 'color', 'voronoi']) + '"); node("M2", "constant", q) }',
                 'node(m, "scalarparam")', 'node(m, "vectorparam", "Tint", 0.5)', 'i = instance(m)', 't = gtree("T")', 'for q in 0..5 { gnode(t, "grid") }', 'add("cube", "Box", 1, 0, 0)']
        for _ in range(self.r.randrange(8, 30)):
            c = self.call()
            lines.append(f'print({c})' if self.r.random() < 0.6 else c)
        lines.append('op("file.save", "@OUT")')
        return '\n'.join(lines)


def s_random():
    print(f'-- {RUNS} random call sequences (seed {SEED}) --')
    rng = random.Random(SEED)
    progs = [Gen(rng).program() for _ in range(RUNS)]

    def one(k):
        ok, why, a = pair(progs[k], f'q{k}', again=k % 10 == 0)
        return ok, k, why, a

    bad, errs = [], 0
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for ok, k, why, a in ex.map(one, range(len(progs))):
            errs += a[0] == 1
            if not ok:
                bad.append((k, why))
    check(not bad, f'{RUNS} random sequences clean, the files read back ({errs} stop at an error)' + ('' if not bad else f': {len(bad)} differ, e.g.\n{progs[bad[0][0]]}\n  {bad[0][1][:800]}'))


# ---- beescript.py's material tasks ---------------------------------------------------------

def s_corpus():
    print("-- beescript.py's material tasks (tests/bscript.py runs all 50; these two again here) --")
    for code in ['m = material("Gold")\nmatset(m, "base", 1, 0.77, 0.34)\nmatset(m, "metallic", 1)\nassign("Cube", m)\nprint(matof("Cube"), matget(m, "metallic"))\nop("file.save", "@OUT")',
                 'select("Cube")\nop("material.preset", "plastic")\nprint(matof("Cube"), matget(matof("Cube"), "metallic"))\nop("file.save", "@OUT")']:
        ok, b = same(code, f'beescript.py task: {code.splitlines()[-2][:60]}: clean, the file reads back', 'task')
        check(b[0] == 0, f'and it ran to the end (rc {b[0]} {b[1][-200:]!r})')


# ---- undo: a run is one step (the console's line, then edit.undo / redo) --------------------

def s_undo():
    print('-- undo / redo of a run: one step (headless; the scenes --eval saves before / after) --')
    body = PRE.replace('\n', '; ').replace('{', '{ ').strip('; ')
    body += '; matset(m, "metallic", 0.7); assign("Cube", m); matparam(i, "Wear", 0.9); nodeset(m, 2, 4, 3); gset(t, 2, 4, 2)'
    a0 = f'{T}/u_e0.bee'
    a1 = f'{T}/u_e1.bee'
    run(BIN, ['--eval', f'op("image.load", "{TEX}")\nop("file.save", "{a0}")'])
    run(BIN, ['--eval', PRE + 'matset(m, "metallic", 0.7)\nassign("Cube", m)\nmatparam(i, "Wear", 0.9)\nnodeset(m, 2, 4, 3)\ngset(t, 2, 4, 2)\n' + f'op("file.save", "{a1}")'])
    check(os.path.exists(a0) and os.path.exists(a1), 'the scenes before and after, saved by --eval')
    p0, p1, p2 = f'{T}/u_p0.bee', f'{T}/u_p1.bee', f'{T}/u_p2.bee'
    # (the image loaded first, by an operator of its own: the run then is the rest)
    b = run(BIN, ['--op', f'image.load {TEX}', '--op', body.replace(f'op("image.load", "{TEX}"); ', ''), '--op', f'file.save {p1}', '--op', 'edit.undo', '--op', f'file.save {p0}',
                  '--op', 'edit.redo', '--op', f'file.save {p2}'])
    check(b[0] == 0, f'BeeModel ran it (rc {b[0]}) {b[2][-200:]!r}')
    for pa, pb, what in ((a1, p1, 'the run: the scene --eval gives'), (a0, p0, 'undone: as before the run'), (a1, p2, 'redone: as after the run')):
        d = scene_diff(pa, pb, () if pb != p0 else (b'UIDS',))
        check(not d, what + ('' if not d else ': ' + d))
    # a failing run: undone as one step too (what it did before the error goes)
    b = run(BIN, ['--op', 'm = material("M"); node(m, "math"); matset(m, "base", 0.1); link(m, 1, 1, 1)', '--op', f'file.save {p1}', '--op', 'edit.undo', '--op', f'file.save {p0}'])
    run(BIN, ['--eval', f'm = material("M")\nnode(m, "math")\nmatset(m, "base", 0.1)\nop("file.save", "{a1}")'])
    run(BIN, ['--eval', f'op("file.save", "{a0}")'])
    d1, d0 = scene_diff(a1, p1), scene_diff(a0, p0, (b'UIDS',))
    check(not d1 and not d0, 'a failing run: what it did before the error kept, then undone in one step' + ('' if not (d1 or d0) else f': {d1} / {d0}'))


# ---- garbage: nothing but its words ----------------------------------------------------------

def s_garbage():
    print('-- random garbage arguments: no crash, no hang --')
    rng = random.Random(SEED + 1)
    pool = EDGE + ['m', 'i', 't', '"' + 'é' * 20 + '"', '-0', '1e-45', '1e308', '"\\n"', '9999999999', '0x7fffffff', '-0x80000000']
    progs = []
    for _ in range(max(RUNS, 100)):
        lines = [PRE]
        for _ in range(30):
            nm = rng.choice(MINE)
            mn, mx = COUNTS[nm]
            n = rng.randrange(mn, mx + 1)
            lines.append(f'x = {nm}({", ".join(rng.choice(pool) for _ in range(n))})')
        progs.append('\n'.join(lines))

    def one(k):
        return k, run(BIN, ['--run', write(f'g{k}.bees', progs[k])], 60)

    bad = []
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for k, b in ex.map(one, range(len(progs))):
            if b[0] not in (0, 1) or 'panic' in b[2]:
                bad.append((k, b))
    check(not bad, f'{len(progs)} garbage runs: each ends with its output or one error' + ('' if not bad else f': {bad[0][1][0]} {bad[0][1][2][-400:]!r}'))


def write(name, text):
    p = os.path.join(T, name)
    open(p, 'w').write(text)
    return p


# ---- memory --------------------------------------------------------------------------------

def s_leak():
    print('-- memory: console runs with these builtins again and again --')
    line = PRE.replace(f'op("image.load", "{TEX}")\n', '').replace('\n', '; ') + 'for q in 0..40 { node(m, "noise"); nodeval(m, 2, 0, q, 0, 0); gnode(t, "grid") }'

    def rss(k):
        h = tempfile.mkdtemp(dir=T)
        a = ['--shot', f'{h}/x.ppm']
        for _ in range(k):
            a += ['--op', line, '--op', 'file.new']
        env = xdg(h)
        env.pop('WAYLAND_DISPLAY', None)
        p = subprocess.Popen([BIN, *a], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(p.pid, 0)
        shutil.rmtree(h, True)
        return st, ru.ru_maxrss
    (s4, r4), (s40, r40) = rss(4), rss(40)
    check(s4 == 0 and s40 == 0 and r40 - r4 < 8192, f'4 runs {r4} KiB, 40 runs {r40} KiB at most: no growth past 8 MiB')


def main():
    print(f'bs_mat: {BIN}, runs {RUNS}, seed {SEED}')
    for nm, f in (('scripts', s_scripts), ('args', s_args), ('random', s_random), ('corpus', s_corpus), ('undo', s_undo),
                  ('garbage', s_garbage), ('leak', s_leak)):
        if want(nm):
            f()
    shutil.rmtree(T, True)
    print(f'bs_mat: {len(FAILS)} fails' if FAILS else 'bs_mat: all checks passed')
    print(f'... fails {len(FAILS)}')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
