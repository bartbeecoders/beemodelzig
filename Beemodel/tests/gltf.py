#!/usr/bin/env python3
"""The glTF 2.0 import and export (gltf.zig, pngenc.zig).

  s_import    files tests/gltf_gen.py writes (every accessor component type,
              strides, offsets, sparse, primitives, modes, TRS / matrix trees,
              scenes, materials with every extension and alpha mode, textures
              with transforms, images as data: URIs, files and buffer views,
              buffers as data: URIs, files and a GLB's BIN chunk) imported:
              the saved .bee reads back with finite vertices, opened and
              saved again the same chunks; the console's words
  s_export    scenes (primitives, parents, modifiers, UVs, vertex colours,
              materials and every value, texture maps used directly and
              baked, lights, cameras, a lightmap): the .glb and the .gltf are
              valid glTF (the views inside their buffers, the accessors inside
              their views, the indices in range), and imported again bring
              the scene's meshes; the selection-only option
  s_obj       the OBJ export's MTL maps, planned as the glTF export plans
              them: the .obj, .mtl and PNGs beside it
  s_round     an export imported, exported and imported again: the same .bee;
              Blender (if there) reads the files and writes files that import
  s_damage    damaged files (cut, bytes flipped, bad lengths, offsets,
              strides, counts, indices, cyclic and deep node trees, bad
              base64, huge numbers): no crash, no hang, the .bee reads back
  s_undo      an import undone and redone; undo after edit mode; a failed
              import leaves no step
  s_window    a .glb dropped (--drop); File > Import > Import glTF... and
              File > Export > Export glTF... open the file browser

    python3 tests/gltf.py BIN [damage-runs=200] [seed]

GLTF_ONLY=s_a,s_b runs only those.
"""
import base64, io, json, os, random, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
import gltf_gen

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 200
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
FAILS = []
T = tempfile.mkdtemp(prefix='beegltf-', dir=os.environ.get('BEEGLTF_TMP', '/tmp'))
ENV = dict(os.environ, BEEMODEL_GPU='off')
GEN = os.path.join(T, 'gen')
CPU = os.environ.get('BEE_CPU', '22')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def run(b, code, timeout=300):
    """--eval in the temp dir: (returncode, stdout); -9 when it ran out of time."""
    try:
        r = subprocess.run([b, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV, cwd=T)
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return -9, ''


def q(p):
    return p.replace('\\', '\\\\').replace('"', '\\"')


def chunks(path):
    d = {}
    for t, c in beefile.chunks(path):
        d.setdefault(t, []).append(c)
    return d


IGNORE = {b'WSPC'}      # (the workspaces: each program's own)


def png_pixels(data):
    from PIL import Image
    try:
        return Image.open(io.BytesIO(data)).convert('RGB').tobytes()
    except Exception:
        return None


def imgd(c):
    """IMGD: per embedded image (index, decoded pixels: RGB)."""
    out, o = [], 0
    while o + 8 <= len(c):
        ix, n = struct.unpack_from('<II', c, o)
        out.append((ix, png_pixels(c[o + 8:o + 8 + n])))
        o += 8 + n
    return out


def imgd_offsets(c):
    o, out = 0, []
    while o + 8 <= len(c):
        out.append(o)
        o += 8 + struct.unpack_from('<I', c, o + 4)[0]
    return out


def compare_bee(a, b):
    """The chunks that differ (two icon meshes at the end, an empty ANIM left
    out, embedded images' PNGs compared as pixels)."""
    A, B = chunks(a), chunks(b)
    bad = []
    for t in sorted(set(A) | set(B)):
        if t in IGNORE:
            continue
        x, y = A.get(t, []), B.get(t, [])
        if t == b'MESH':
            if x != y[:len(x)] or len(y) - len(x) not in (0, 2):
                bad.append('MESH %d %d' % (len(x), len(y)))
            continue
        if t == b'ANIM' and x == [b''] and y == []:
            continue
        if t == b'IMGD':
            if [imgd(c) for c in x] != [imgd(c) for c in y]:
                bad.append('IMGD pixels')
            continue
        if x != y:
            bad.append('%s %s %s' % (t.decode(), [len(c) for c in x], [len(c) for c in y]))
    return bad


CLEAR = 'n = count()\nfor i in 0..n { delete(name(0)) }\n'


def bee_after(b, path, before='', extra='', tag='x'):
    out = os.path.join(T, '%s-%d.bee' % (tag, random.randrange(1 << 30)))
    code = '%s%s\nop("file.import_gltf", "%s")\n%s\nop("file.save", "%s")' % (CLEAR, before, q(path), extra, out)
    rc, so = run(b, code)
    return (out if os.path.exists(out) else None), rc, so


def said(so):
    """The console's words about the import (the image lines and the result)."""
    return [ln.strip() for ln in so.splitlines() if ln.strip().startswith(('imported', 'not a valid', 'could not', 'image:'))]


def finite_bee(path, finite=True):
    """The .bee reads back: objects, meshes with indices in range and (finite)
    finite vertices and places."""
    import math
    try:
        ob = beefile.objects(path)
        ms = beefile.meshes(path)
    except Exception:
        return False
    return all((not finite or all(math.isfinite(c) for v in vs for c in v)) and all(0 <= i < len(vs) for p in ps for i in p) for vs, ps in ms) \
        and (not finite or all(math.isfinite(x) for o in ob for x in o['loc'] + o['rot'] + o['scl']))


def by_name(path):
    """{object name: (place, mesh verts, polygons)}: a scene whatever its order."""
    ms = beefile.meshes(path)
    return {o['name']: (o['loc'] + o['rot'] + o['scl'], ms[o['mesh']] if o['type'] == 0 and o['mesh'] < len(ms) else None) for o in beefile.objects(path)}


def same_scene(a, b, tol=1e-5):
    """What differs between two scenes taken by name (places, vertices, polygons)."""
    A, B = by_name(a), by_name(b)
    bad = [] if set(A) == set(B) else ['names %s' % sorted(set(A) ^ set(B))[:4]]
    for k in set(A) & set(B):
        (pa, ma), (pb, mb) = A[k], B[k]
        if any(abs(x - y) > tol for x, y in zip(pa, pb)):
            bad.append('%s: place' % k)
        if (ma is None) != (mb is None) or (ma and (ma[1] != mb[1] or len(ma[0]) != len(mb[0]) or any(abs(x - y) > tol for u, v in zip(ma[0], mb[0]) for x, y in zip(u, v)))):
            bad.append('%s: mesh' % k)
    return bad


def import_ok(path, before='', extra=''):
    """Imported, saved, read back; opened and saved again: (what is wrong, objects)."""
    a, rc, so = bee_after(BIN, path, before, extra, 'p')
    if not a:
        return ['no file (rc %d)' % rc], 0
    bad = [] if finite_bee(a) else ['not finite or out of range']
    b = os.path.join(T, 're-%d.bee' % random.randrange(1 << 30))
    run(BIN, 'op("file.open", "%s")\nop("file.save", "%s")' % (q(a), q(b)))
    bad += compare_bee(a, b) if os.path.exists(b) else ['not saved again']
    n = len(beefile.objects(a))
    for x in (a, b):
        if os.path.exists(x):
            os.remove(x)
    return bad, n


def port_log(*lines):
    """The port's console after a script (headless, --dump-log): its lines."""
    sc = os.path.join(T, 'log-%d.bees' % random.randrange(1 << 30))
    open(sc, 'w').write(CLEAR + '\n'.join(lines) + '\n')
    lg = os.path.join(T, 'log-%d.txt' % random.randrange(1 << 30))
    subprocess.run([BIN, '--shot', os.path.join(T, 'l.ppm'), '--op', 'script.run %s' % sc, '--dump-log', lg],
                   capture_output=True, text=True, timeout=300, env=ENV, cwd=T)
    out = open(lg, errors='replace').read().splitlines() if os.path.exists(lg) else []
    for f in (sc, lg, os.path.join(T, 'l.ppm')):
        if os.path.exists(f):
            os.remove(f)
    return out


def gen():
    if not os.path.isdir(GEN):
        os.makedirs(GEN)
        gltf_gen.cases(GEN, SEED % 100000)
    return sorted(os.path.join(GEN, f) for f in os.listdir(GEN) if f.endswith(('.gltf', '.glb')))


# ---- the import ------------------------------------------------------------------------

def s_import():
    print('-- the import: files of every kind --', flush=True)
    files = gen()
    tot, bad = 0, []
    for f in files:
        b, n = import_ok(f)
        tot += n
        if b:
            bad.append((os.path.basename(f), b[:4]))
    for x in bad[:8]:
        print('       %s: %s' % x)
    check(len(files) >= 20 and not bad and tot > 100,
          '%d files: %d objects, each .bee read back finite, opened and saved again the same (%d not)' % (len(files), tot, len(bad)))
    # what came in, by the program's answers
    f = os.path.join(GEN, 'textures.glb')
    code = (CLEAR + 'op("file.import_gltf", "%s")\n'
            'for i in 0..count() { o = name(i)\n print("OB", o, matof(o)) }\n'
            'm = matof("Ball0")\nprint("N", nodeinfo(m, 0, "count"), nodeinfo(m, 0, "socket", 0) > 0, matget(m, "blend"))\n'
            'print("I", imgsize("checker", 0), imgsize("orm", 0), imgsize("photo", 0))' % f)
    _, b = run(BIN, code)
    obs = [ln.split()[1:] for ln in b.splitlines() if ln.startswith('OB ')]
    check(len(obs) == 4 and obs[-1] == ['Ball0', 'Textured'] and obs[0] == ['Ball3', 'Masked'],
          'four spheres, each its material, the last root first (%s)' % obs)
    nl = next((ln.split()[1:] for ln in b.splitlines() if ln.startswith('N ')), [])
    il = next((ln.split()[1:] for ln in b.splitlines() if ln.startswith('I ')), [])
    check(len(nl) == 3 and float(nl[0]) > 1 and nl[1] in ('1', 'true') and len(il) == 3 and all(float(x) > 0 for x in il),
          'the materials\' graphs have nodes and a linked socket, the images their sizes (%s)' % [ln for ln in b.splitlines() if ln[:2] in ('N ', 'I ')])
    # a JPEG from a buffer view stays a JPEG in the .bee: its bytes kept
    b, _, _ = bee_after(BIN, f, tag='jp')
    raw = lambda x: [c[o + 8:o + 8 + struct.unpack_from('<I', c, o + 4)[0]] for c in chunks(x).get(b'IMGD', []) for o in imgd_offsets(c)] if x else []
    jb = [x for x in raw(b) if x[:2] == b'\xff\xd8']
    src = open(f, 'rb').read()
    check(jb and all(x in src for x in jb), 'the buffer view\'s JPEG saved in the .bee as it came, byte for byte (%d JPEG)' % len(jb))
    # the console's words (formats.s result: "  imported", "  could not read", "  not a valid file:")
    lg = port_log('op("file.export_gltf", "/tmp/x.glb")', 'op("file.import_gltf", "%s")' % os.path.join(GEN, 'cube.glb'),
                  'op("file.import_gltf", "%s/none.glb")' % T, 'op("file.import_gltf", "%s")' % os.path.join(GEN, 'my tex.png'),
                  'op("file.import_gltf", "%s")' % os.path.join(GEN, 'textures.glb'))
    want = ['  imported %s' % os.path.join(GEN, 'cube.glb'), '  could not read %s/none.glb' % T,
            '  not a valid file: %s' % os.path.join(GEN, 'my tex.png'), '  not a valid file: /tmp/x.glb',
            '  image: my tex 8 x 8']
    check(all(w in lg for w in want), 'the console says: imported, could not read, not a valid file (also an export of nothing), the image file\'s line (%s)'
          % [w for w in want if w not in lg])


# ---- the export ------------------------------------------------------------------------

SC_PLAIN = 'op("file.new")\n'
SC_MIX = CLEAR + '''
a = add("cube", "Box", 1, 2, 3)
rotate(a, 0.3, 1.2, -0.7)
scale(a, 1, 2, 0.5)
b = add("sphere", "Ball", -2, 0, 1)
c = add("cylinder", "Can", 0.5, 0, -3)
rotate(c, 0, 0, 2.5)
op("object.parent_set", "Can Box")
p = add("plane", "Flat \\"q\\" caf\u00e9", 0, -1, 0)
scale(p, 4, 1, 4)
unwrap(p)
modifier("Ball", "subsurf")
modset("Ball", 0, "levels", 2)
vpaint("Box", 1, 2, 3, 2.5, 255, 40, 0)
vpaint("Ball", -2, 0.5, 1, 0.8, 0, 90, 255)
g = material("Glass")
matset(g, "transmission", 1)
matset(g, "ior", 1.52)
matset(g, "roughness", 0.05)
matset(g, "alpha", 0.4)
e = material("Glow")
matset(e, "emission", 1, 0.4, 0.1)
matset(e, "strength", 8)
m = material("Mask")
matset(m, "blend", 1)
matset(m, "clip", 0.37)
matset(m, "one_sided", 1)
k = material("Coat")
matset(k, "base", 0.1, 0.2, 0.3)
matset(k, "metallic", 0.9)
matset(k, "clearcoat", 0.8)
matset(k, "coat_roughness", 0.2)
matset(k, "blend", 2)
z = material("Zero")
matset(z, "blend", 1)
matset(z, "clip", 0)
assign("Box", g)
assign("Ball", e)
assign("Can", m)
assign(p, k)
add("light", "Lamp2", 3, 4, 5)
add("camera", "Cam2", 0, 1, 8)
rotate("Cam2", -0.2, 0.1, 0)
add("cube", "Plain", 0, 3, 0)
'''


def tex_set(d):
    from PIL import Image
    os.makedirs(d, exist_ok=True)
    im = Image.new('RGB', (32, 32))
    im.putdata([((150 + (x // 8 + y // 8) % 2 * 60), 120, 90) for y in range(32) for x in range(32)])
    im.save(os.path.join(d, 'Tiles_BaseColor_1k.png'))
    Image.new('RGB', (16, 16), (128, 128, 255)).save(os.path.join(d, 'Tiles_Normal_GL_1k.png'))
    Image.new('RGB', (16, 16), (140, 140, 140)).save(os.path.join(d, 'Tiles_Roughness_1k.png'))
    Image.new('RGB', (16, 16), (230, 230, 230)).save(os.path.join(d, 'Tiles_AO_1k.png'))
    Image.new('RGB', (16, 16), (30, 200, 230)).save(os.path.join(d, 'Tiles_Emission_1k.png'))


def sc_maps(tex):
    return CLEAR + f'''f = add("plane", "Floor", 0, -1, 0)
scale(f, 5, 1, 5)
unwrap(f)
select(f)
op("material.import_textures", "{tex}/Tiles_BaseColor_1k.png")
c = material("Crate")
t = node(c, "texcoord", 2, 2)
k = node(c, "checker", 6)
link(c, t, k, 1)
socket(c, "base", k)
socket(c, "roughness", k)
o = add("cube", "Crate0", -2, -0.6, 2)
unwrap(o, "smart")
assign(o, c)
i = image("{tex}/Tiles_BaseColor_1k.png")
d = material("Direct")
s = node(d, "image", i)
socket(d, "base", s)
socket(d, "emission", s)
x = add("sphere", "Direct", 3, 0, 0)
unwrap(x)
assign(x, d)
j = image("{tex}/Tiles_AO_1k.png")
e = material("Packed")
n1 = node(e, "image", i)
socket(e, "metallic", n1, 3)
socket(e, "roughness", n1, 2)
socket(e, "ao", n1, 1)
nm = node(e, "normalmap")
nodeset(e, nm, 4, 0.7)
link(e, n1, nm, 1)
socket(e, "normal", nm)
tc = node(e, "texcoord", 1, 1, 0, 0)
n2 = node(e, "image", j)
link(e, tc, n2, 1)
socket(e, "base", n2)
y = add("sphere", "Packed", -3, 0, 0)
unwrap(y)
assign(y, e)
sw = material("Swapped")
m5 = node(sw, "image", i)
socket(sw, "metallic", m5, 2)
socket(sw, "roughness", m5, 3)
y2 = add("sphere", "Swapped", -3, 3, 0)
unwrap(y2)
assign(y2, sw)
tl = material("Tiled")
t2 = node(tl, "texcoord", 2, 2, 0, 0)
n3 = node(tl, "image", j)
link(tl, t2, n3, 1)
socket(tl, "base", n3)
tt = add("cube", "TiledBox", 3, 3, 0)
unwrap(tt, "smart")
assign(tt, tl)
h = material("TwoImages")
m1 = node(h, "image", i)
m2 = node(h, "image", j)
socket(h, "metallic", m1, 3)
socket(h, "roughness", m2, 2)
u = add("cube", "Two", 0, 3, 0)
unwrap(u, "smart")
assign(u, h)
v = material("Unused")
m3 = node(v, "image", j)
socket(v, "base", m3)
nb = material("NoUVs")
m4 = node(nb, "checker")
socket(nb, "base", m4)
add("cube", "NoUVs", 0, -3, 0)
assign("NoUVs", nb)
render("{T}/r.png", 8, 8, 1)
'''


def sc_wood():
    return CLEAR + '''w = add("cube", "Box", 1.6, -0.2, -1)
unwrap(w, "smart")
select(w)
op("material.preset", "wood")
'''


def lightmap_bee():
    """A scene with a lightmap baked once and saved."""
    bee = os.path.join(T, 'lit.bee')
    if os.path.exists(bee):
        return bee
    code = CLEAR + '''add("plane", "Floor", 0, 0, 0)
scale("Floor", 6)
add("cube", "Roof", 0, 2, 0)
scale("Roof", 2, 0.1, 2)
material("Red")
matset("Red", "emission", 1, 0.05, 0.05)
matset("Red", "strength", 8)
assign("Roof", "Red")
add("sphere", "Ball", 2, 1, 1)
add("light", "Lamp", 2, 4, 2)
unwrap("Ball")
op("lightmap.bake", "64 16")
op("file.save", "%s")''' % bee
    run(BIN, code, 600)
    return bee if os.path.exists(bee) else None


def export(code, tag):
    """The code run, then .glb and .gltf exported: [glb bytes, gltf path] (or None)."""
    g1 = os.path.join(T, '%s.glb' % tag)
    g2 = os.path.join(T, '%s.gltf' % tag)
    rc, so = run(BIN, code + '\nop("file.export_gltf", "%s")\nop("file.export_gltf", "%s")' % (g1, g2), 600)
    return [open(g1, 'rb').read() if os.path.exists(g1) else None, g2 if os.path.exists(g2) else None]


ACOMP = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
ATYPE = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT2': 4, 'MAT3': 9, 'MAT4': 16}


def gltf_check(path_or_glb):
    """What is wrong with an exported glTF (empty when nothing): the version,
    the buffers there and long enough, the views in them, the accessors in
    their views, the indices in range, the nodes' references."""
    why = []
    try:
        if isinstance(path_or_glb, bytes):
            d = path_or_glb
            if d[:4] != b'glTF' or struct.unpack_from('<I', d, 8)[0] != len(d):
                return ['not a GLB of its length']
            n = struct.unpack_from('<I', d, 12)[0]
            j = json.loads(d[20:20 + n])
            bins = [d[20 + n + 8:20 + n + 8 + struct.unpack_from('<I', d, 20 + n)[0]]] if len(d) > 20 + n else [b'']
        else:
            j = json.load(open(path_or_glb))
            bins = []
            for b in j.get('buffers', []):
                u = b.get('uri', '')
                if u.startswith('data:'):
                    bins.append(base64.b64decode(u.split(',', 1)[1]))
                else:
                    bins.append(open(os.path.join(os.path.dirname(path_or_glb), u), 'rb').read())
    except Exception as e:
        return ['unreadable: %r' % e]
    if j.get('asset', {}).get('version') != '2.0':
        why.append('asset.version')
    for k, b in enumerate(j.get('buffers', [])):
        if k >= len(bins) or len(bins[k]) < b.get('byteLength', 0):
            why.append('buffer %d short' % k)
    views = j.get('bufferViews', [])
    for k, v in enumerate(views):
        if v.get('byteOffset', 0) + v['byteLength'] > j['buffers'][v['buffer']]['byteLength']:
            why.append('view %d past its buffer' % k)
    acc = j.get('accessors', [])
    for k, a in enumerate(acc):
        if 'bufferView' not in a:
            continue
        v = views[a['bufferView']]
        es = ACOMP[a['componentType']] * ATYPE[a['type']]
        st = v.get('byteStride', es)
        if a['count'] and a.get('byteOffset', 0) + (a['count'] - 1) * st + es > v['byteLength']:
            why.append('accessor %d past its view' % k)
        if a['componentType'] == 5126 and a.get('min') and not all(abs(x) < 1e30 for x in a['min'] + a.get('max', [])):
            why.append('accessor %d bounds' % k)

    def values(k):
        a = acc[k]
        v = views[a['bufferView']]
        buf = bins[v['buffer']]
        fmt = {5121: 'B', 5123: 'H', 5125: 'I'}[a['componentType']]
        o = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        return struct.unpack_from('<%d%s' % (a['count'], fmt), buf, o)
    for m in j.get('meshes', []):
        for pr in m['primitives']:
            npos = acc[pr['attributes']['POSITION']]['count']
            if 'indices' in pr and acc[pr['indices']].get('bufferView') is not None:
                ix = values(pr['indices'])
                if ix and max(ix) >= npos:
                    why.append('indices past the vertices in %s' % m.get('name'))
            if 'material' in pr and pr['material'] >= len(j.get('materials', [])):
                why.append('a material past the list')
    for k, nd in enumerate(j.get('nodes', [])):
        if nd.get('mesh', 0) >= max(1, len(j.get('meshes', []))) or any(c >= len(j['nodes']) for c in nd.get('children', [])):
            why.append('node %d references' % k)
    for t in j.get('textures', []):
        if t.get('source', 0) >= len(j.get('images', [])):
            why.append('a texture past the images')
    return why


def gdiff(a, b):
    """Where two glTF files part: the JSON keys around it."""
    if a is None or b is None:
        return 'missing %s %s' % (a is None, b is None)
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return '@%d: %r / %r' % (i, a[max(0, i - 60):i + 40], b[max(0, i - 60):i + 40])
    return 'lengths %d %d' % (len(a), len(b))


def glb_images(d):
    """[(name, PNG bytes)] of a .glb's images"""
    j = glb_json(d)
    bo = 20 + struct.unpack_from('<I', d, 12)[0] + 8
    out = []
    for im in j.get('images', []):
        v = j['bufferViews'][im['bufferView']]
        out.append((im.get('name'), d[bo + v.get('byteOffset', 0):bo + v.get('byteOffset', 0) + v['byteLength']]))
    return out


def norm_views(j):
    """the JSON with the views' offsets and lengths and the buffer's length gone"""
    for v in j.get('bufferViews', []):
        v.pop('byteOffset', None)
        v.pop('byteLength', None)
    for b in j.get('buffers', []):
        b.pop('byteLength', None)
    return j


def pixdiff(a, b):
    """(pixels that differ, the most a channel differs) of two PNGs"""
    from PIL import Image
    x = Image.open(io.BytesIO(a)).convert('RGBA')
    y = Image.open(io.BytesIO(b)).convert('RGBA')
    if x.size != y.size:
        return 1 << 30, 255
    p, q = x.tobytes(), y.tobytes()
    n = sum(1 for i in range(0, len(p), 4) if p[i:i + 4] != q[i:i + 4])
    return n, max((abs(u - v) for u, v in zip(p, q)), default=0)


def px_set(d):
    from PIL import Image
    return set(Image.open(io.BytesIO(d)).convert('RGBA').get_flattened_data())


def maps_scene(code):
    """Before any render, the colour maps baked are not black (the sRGB table
    made when needed)."""
    code = code.replace('render("%s/r.png", 8, 8, 1)\n' % T, '')
    p = export(code, 'maps0')[0]
    if not p:
        return check(False, 'maps without a render first: exported')
    b = dict(glb_images(p))
    black = lambda d: px_set(d) <= {(0, 0, 0, 0), (0, 0, 0, 255)}
    check('Tiles_base' in b and not black(b['Tiles_base']) and not black(b['Tiles_emissive']),
          'before any render the colour maps are baked, not black')


def glb_json(d):
    n = struct.unpack_from('<I', d, 12)[0]
    return json.loads(d[20:20 + n])


def mesh_names(bee):
    return sorted(o['name'] for o in beefile.objects(bee) if o['type'] == 0)


def s_export():
    print('-- the export: valid glTF, imported again --', flush=True)
    tex = os.path.join(T, 'tex')
    tex_set(tex)
    scenes = [('plain', SC_PLAIN, 'the default scene: a cube, a light, a camera'),
              ('mix', SC_MIX, 'transforms, a parent, subsurf, UVs, vertex colours, every material value, lights, cameras'),
              ('maps', sc_maps(tex), 'a texture set (maps used directly) and graphs baked to 512 x 512 maps')]
    lb = lightmap_bee()
    check(lb is not None, 'a lightmap baked and saved')
    if lb:
        scenes.append(('lightmap', 'op("file.open", "%s")' % lb, 'a lightmap: the atlas, TEXCOORD_1, MOZ_lightmap'))
    for tag, code, what in scenes:
        if tag == 'maps':
            maps_scene(code)
        p = export(code, tag)
        bad = (gltf_check(p[0]) if p[0] else ['no .glb']) + (gltf_check(p[1]) if p[1] else ['no .gltf'])
        check(not bad, '%s: the .glb (%s bytes) and the .gltf valid (%s)' % (what, len(p[0] or b''), bad[:3]))
        if p[0]:
            g = os.path.join(T, '%s-re.glb' % tag)
            open(g, 'wb').write(p[0])
            j = glb_json(p[0])
            want = sorted(n.get('name', '') for n in j.get('nodes', []) if 'mesh' in n)
            got = {}
            for f in (g, p[1]):
                bee, rc, _ = bee_after(BIN, f, tag='ex')
                got[f] = (mesh_names(bee) if bee else None, finite_bee(bee) if bee else False)
            check(all(x == (want, True) for x in got.values()) and want,
                  '%s: imported again (.glb and .gltf), its %d meshes, finite' % (tag, len(want)))
        if tag == 'maps' and p[0]:
            j = glb_json(p[0])
            names = sorted(i.get('name', '') for i in j.get('images', []))
            check(any(n.startswith('Tiles') for n in names) and any(n.endswith('_base') for n in names),
                  'the maps: images used directly and baked ones (%s)' % names)
            pk = next((m for m in j['materials'] if m['name'] == 'Packed'), {})
            pb = pk.get('pbrMetallicRoughness', {})
            ims = [i.get('name') for i in j['images']]
            tx = lambda k: ims[j['textures'][k]['source']] if k is not None and k < len(j['textures']) else None
            check(pk.get('normalTexture', {}).get('scale') == 0.7 and tx(pb.get('metallicRoughnessTexture', {}).get('index')) == 'Tiles_BaseColor_1k.001'
                  and pk.get('occlusionTexture') == pb.get('metallicRoughnessTexture') and tx(pb.get('baseColorTexture', {}).get('index')) == 'Tiles_AO_1k.001'
                  and pb.get('metallicFactor') == 1, 'one image as metallic (B), roughness (G), occlusion (R) and a normal map (scale 0.7); a plain Texture Coordinate: used directly (%s)' % pk)
        if tag == 'lightmap' and p[0]:
            j = glb_json(p[0])
            check('MOZ_lightmap' in j.get('extensionsUsed', []) and j['images'][0]['name'] == 'lightmap',
                  'the lightmap image first, MOZ_lightmap used (%s)' % j.get('extensionsUsed'))
    # a procedural wood baked: base and ORM maps, not flat
    p = export(sc_wood(), 'wood')[0]
    if p:
        b = glb_images(p)
        check(not gltf_check(p) and len(b) == 2 and len(px_set(b[0][1])) > 4 and all(png_pixels(x) for _, x in b),
              'a procedural wood baked to base and ORM maps: %d images, the base with its grain (%s colours)' % (len(b), [len(px_set(x)) for _, x in b]))
    else:
        check(False, 'a procedural wood: exported')


def s_obj():
    """formats.s's MTL export takes its maps from gx_tex_plan too."""
    print('-- the OBJ export\'s maps (gx_tex_plan) --', flush=True)
    tex = os.path.join(T, 'tex')
    tex_set(tex)
    d = os.path.join(T, 'obj-p')
    os.makedirs(d, exist_ok=True)
    run(BIN, sc_maps(tex) + '\nop("file.export_obj", "%s/scene.obj")' % d, 600)
    p = {f: open(os.path.join(d, f), 'rb').read() for f in sorted(os.listdir(d))}
    pngs = sorted(f for f in p if f.endswith('.png'))
    mtl = p.get('scene.mtl', b'').decode(errors='replace')
    obj = p.get('scene.obj', b'').decode(errors='replace')
    nv = sum(1 for ln in obj.splitlines() if ln.startswith('v '))
    fs = [int(w.split('/')[0]) for ln in obj.splitlines() if ln.startswith('f ') for w in ln.split()[1:]]
    check(obj.startswith('#') or 'mtllib scene.mtl' in obj, 'the .obj names its .mtl')
    check(nv > 0 and fs and all(1 <= abs(i) <= nv for i in fs), 'the .obj: %d vertices, every face\'s index in range' % nv)
    used = {ln.split()[-1] for ln in mtl.splitlines() if ln.startswith(('map_', 'norm', 'bump'))}
    gone = [u for u in used if not (u in pngs or (os.path.isabs(u) and os.path.exists(u)))]
    check(pngs and not gone and all(png_pixels(p[f]) for f in pngs) and 'map_Kd Tiles_base.png' in mtl and 'map_Pr -imfchan g Tiles_orm.png' in mtl,
          'the baked and embedded maps beside it, the images used directly by their paths, every one there and readable (%s%s)' % (pngs, gone))


# ---- round trips ------------------------------------------------------------------------

BLENDER = '/usr/bin/blender'
BL_READ = """
import bpy, sys, json
a = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=a[0])
out = []
for o in bpy.context.scene.objects:
    d = {'name': o.name, 'type': o.type, 'loc': [round(x, 4) for x in o.matrix_world.translation]}
    if o.type == 'MESH':
        me = o.data
        d['verts'] = len(me.vertices)
        d['tris'] = sum(len(p.vertices) - 2 for p in me.polygons)
        d['uv'] = len(me.uv_layers)
        d['mat'] = o.active_material.name if o.active_material else None
    out.append(d)
json.dump(sorted(out, key=lambda d: d['name']), open(a[1], 'w'))
"""
BL_WRITE = """
import bpy, sys, math
a = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, location=(1, 2, 3))
s = bpy.context.object
s.name = 'Globe'
s.rotation_euler = (0.3, 0.2, 0.1)
s.scale = (1, 2, 1)
m = bpy.data.materials.new('Paint')
m.use_nodes = True
b = m.node_tree.nodes['Principled BSDF']
b.inputs['Base Color'].default_value = (0.8, 0.2, 0.1, 1)
b.inputs['Metallic'].default_value = 0.6
b.inputs['Roughness'].default_value = 0.3
im = bpy.data.images.new('grid', 8, 8)
im.pixels = [((i // 4 + i // 32) % 2) * 1.0 if (i % 4) != 3 else 1.0 for i in range(8 * 8 * 4)]
im.file_format = 'PNG'
t = m.node_tree.nodes.new('ShaderNodeTexImage')
t.image = im
m.node_tree.links.new(t.outputs['Color'], b.inputs['Base Color'])
s.data.materials.append(m)
bpy.ops.mesh.primitive_cube_add(location=(-2, 0, 0))
c = bpy.context.object
c.name = 'Crate'
bpy.ops.object.empty_add(location=(0, 1, 0))
e = bpy.context.object
e.rotation_euler = (0, 0, math.radians(30))
c.parent = e
bpy.ops.mesh.primitive_cylinder_add(vertices=12, location=(0, 0, -3))
bpy.ops.object.light_add(type='POINT', location=(4, 4, 4))
bpy.ops.object.camera_add(location=(0, -8, 2))
bpy.ops.export_scene.gltf(filepath=a[0], export_format=a[1])
"""


def blender(script, *args):
    """Blender in the background with the test's HOME and XDG folders, factory settings."""
    sc = os.path.join(T, 'bl-%d.py' % random.randrange(1 << 30))
    open(sc, 'w').write(script)
    try:
        r = subprocess.run([BLENDER, '--factory-startup', '-b', '--python', sc, '--', *args], capture_output=True, text=True,
                           timeout=300, env=ENV, cwd=T)
        return r.returncode
    except subprocess.TimeoutExpired:
        return -9


def s_round():
    print('-- round trips: exported, imported, exported and imported again; Blender --', flush=True)
    for tag, code in (('mix', SC_MIX), ('plain', SC_PLAIN)):
        for ext in ('glb', 'gltf'):
            g1 = os.path.join(T, 'r-%s-p.%s' % (tag, ext))
            g2 = os.path.join(T, 'r-%s-p2.%s' % (tag, ext))
            run(BIN, code + '\nop("file.export_gltf", "%s")' % g1)
            a, _, _ = bee_after(BIN, g1, tag='r1')
            run(BIN, CLEAR + 'op("file.import_gltf", "%s")\nop("file.export_gltf", "%s")' % (q(g1), q(g2)))
            b, _, _ = bee_after(BIN, g2, tag='r2')
            res = same_scene(a, b) if a and b else ['missing']
            n = len(beefile.objects(a)) if a else 0
            check(res == [] and n >= (5 if tag == 'mix' else 1), '%s .%s: exported, imported, exported and imported again: the same objects, places and meshes (%d objects%s)'
                  % (tag, ext, n, '' if not res else ', ' + str(res[:3])))
    if not os.path.exists(BLENDER):
        check(False, 'Blender (%s) to read and write glTF: not installed' % BLENDER)
        return
    # Blender reads the files
    for ext in ('glb', 'gltf'):
        gp = os.path.join(T, 'r-mix-p.%s' % ext)
        js = os.path.join(T, 'bl-%s.json' % ext)
        rc = blender(BL_READ, gp, js)
        objs = json.load(open(js)) if os.path.exists(js) else []
        meshes = [o for o in objs if o['type'] == 'MESH']
        box = next((o for o in meshes if o['name'] == 'Box'), {})
        check(rc == 0 and len(meshes) == 5 and box.get('tris') == 12 and box.get('mat') == 'Glass' and box.get('loc') == [1.0, -3.0, 2.0]
              and any(o['type'] == 'LIGHT' for o in objs) and any(o['type'] == 'CAMERA' for o in objs)
              and next((o for o in meshes if o['name'].startswith('Flat')), {}).get('uv') == 1,
              'Blender reads the .%s: %d meshes (Box: 12 triangles, Glass, at 1 2 3 Y up = 1 -3 2 in Blender; the plane with UVs), a light, a camera (rc %d)'
              % (ext, len(meshes), rc))
    # files Blender writes, imported
    for fmt, ext in (('GLB', 'glb'), ('GLTF_SEPARATE', 'gltf')):
        f = os.path.join(T, 'bl-%s.%s' % (fmt, ext))
        rc = blender(BL_WRITE, f, fmt)
        if rc != 0 or not os.path.exists(f):
            check(False, 'Blender wrote a %s (rc %d)' % (fmt, rc))
            continue
        bad, n = import_ok(f)
        check(not bad and n >= 3, 'Blender\'s %s (normals, tangents, a texture, an empty parent): imported, read back, saved again the same (%d objects%s)'
              % (fmt, n, '' if not bad else ', ' + str(bad[:3])))


# ---- undo, the window ------------------------------------------------------------------

VIEW = (212, 80, 1022, 630)     # (the 3D viewport of the default workspace: the console says what was done)


def port(*a, log=None):
    lg = log or os.path.join(T, 'log.txt')
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', os.path.join(T, 'u.ppm'), '--dump-log', lg, '--dump-ui', os.path.join(T, 'u.txt'), *a],
                       capture_output=True, text=True, timeout=600, env=ENV, cwd=T)
    return r, (open(lg, errors='replace').read() if os.path.exists(lg) else '')


def s_undo():
    print('-- undo --', flush=True)
    f = os.path.join(GEN, 'textures.glb')
    gen()
    b = lambda n: os.path.join(T, n)
    from PIL import Image
    port('--op', 'file.save %s' % b('u0.bee'))
    shot0 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    port('--op', 'file.import_gltf %s' % f, '--op', 'file.save %s' % b('u1.bee'))
    shot1 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    r, lg = port('--op', 'file.import_gltf %s' % f, '--op', 'edit.undo', '--op', 'file.save %s' % b('u2.bee'))
    shot2 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    port('--op', 'file.import_gltf %s' % f, '--op', 'edit.undo', '--op', 'edit.redo', '--op', 'file.save %s' % b('u3.bee'))
    shot3 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    n0, n1 = len(beefile.objects(b('u0.bee'))), len(beefile.objects(b('u1.bee')))
    bad2 = compare_bee(b('u0.bee'), b('u2.bee'))
    bad3 = compare_bee(b('u1.bee'), b('u3.bee'))
    # (images and materials are not in undo steps: an undone import leaves them)
    check(n1 == n0 + 4 and not [x for x in bad2 if not x.startswith(('IMGS', 'IMGD', 'UIDS', 'MATS', 'MGRF'))] and not bad3,
          'import, undo, redo: %d objects, %d, then the import\'s scene again chunk for chunk (%s %s)' % (n1, n0, bad2[:2], bad3[:2]))
    check(shot2 == shot0 and shot1 != shot0 and shot3 == shot1, 'the 3D view after undo is the view before the import; after redo, after it')
    port('--op', 'file.import_gltf %s' % f, '--select', 'Ball0', '--key', 'tab', '--key', 'tab', '--op', 'edit.undo', '--op', 'file.save %s' % b('u4.bee'))
    n4 = len(beefile.objects(b('u4.bee'))) if os.path.exists(b('u4.bee')) else -1
    check(n4 == n0, 'undo after edit mode on and off: the import undone (%d objects)' % n4)
    r, lg = port('--op', 'file.import_gltf /nonexistent/x.glb', '--op', 'file.save %s' % b('u5.bee'))
    check('could not read /nonexistent/x.glb' in lg and not compare_bee(b('u0.bee'), b('u5.bee')), 'a file that is not there: said so, the scene as it was')
    # a file whose materials come in but nothing else (no undo step for it)
    bad = os.path.join(T, 'matsonly.gltf')
    open(bad, 'w').write(json.dumps({'asset': {'version': '2.0'}, 'scenes': [{'nodes': [0]}], 'nodes': [{}],
                                     'materials': [{'name': 'Lone'}]}))
    r, lg = port('--op', 'file.import_gltf %s' % bad, '--op', 'edit.undo', '--op', 'file.save %s' % b('u6.bee'))
    hist = [ln for ln in open(b('u.txt'), errors='replace').read().splitlines() if ln.startswith('status\t')]
    m6 = beefile.chunk(b('u6.bee'), b'MATS') if os.path.exists(b('u6.bee')) else b''
    check('not a valid file: ' + bad in lg and b'Lone' in (m6 or b'') and 'nothing to undo' in lg.lower() + ' '.join(hist).lower(),
          'nothing to import: "not a valid file", its material stays, no undo step made for it (%s)' % [ln for ln in lg.splitlines()[-3:]])


def s_window():
    print('-- the window --', flush=True)
    gen()
    glb = os.path.join(GEN, 'textures.glb')
    r, lg = port('--drop', 'file://' + glb + '\r\n')
    ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
    stat = next((ln.split('\t')[1] for ln in ui.splitlines() if ln.startswith('status\t')), '')
    check('imported ' + glb in lg and stat.split('|')[1].split()[0] == '7', 'a dropped .glb is imported (%s)' % stat)
    for menu, item, btn in (('Import', 'Import glTF...', 'Open'), ('Export', 'Export glTF...', 'Save')):
        r, lg = port('--click-label', 'File', '--click-label', menu)
        ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
        row = [ln for ln in ui.splitlines() if ln.startswith('menuitem\t%s\t' % item)]
        check(row and row[0].endswith('\ton'), 'File > %s has %s, not greyed' % (menu, item))
        r, lg = port('--click-label', 'File', '--click-label', menu, '--click-label', item)
        ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
        from PIL import Image
        Image.open(os.path.join(T, 'u.ppm')).convert('RGB').save(os.path.join(os.environ.get('GLTF_SHOTS', T), 'browser-%s.png' % menu))
        check('button\t%s\t' % btn in ui and 'button\tCancel\t' in ui and 'menuitem\t' not in ui
              and (menu == 'Import' or 'checkbox\tSelected objects only' in ui),
              '%s offers the file browser (%s, Cancel%s)' % (item, btn, '' if menu == 'Import' else ', Selected objects only'))
    # Selected objects only: the file is the scene's with the others gone
    sc = os.path.join(T, 'mix.bees')
    open(sc, 'w').write(SC_MIX + 'select("Ball")\n')
    out = '/tmp/beemodel-headless/BeeModel/scene.glb'
    if os.path.exists(out):
        os.remove(out)
    r, lg = port('--op', 'script.run %s' % sc, '--click-label', 'File', '--click-label', 'Export', '--click-label', 'Export glTF...',
                 '--click-label', 'checkbox:Selected objects only', '--click-label', 'button:Save')
    got = open(out, 'rb').read() if os.path.exists(out) else None
    if os.path.exists(out):
        os.remove(out)   # (the headless home is everyone's)
    ref = os.path.join(T, 'sel-p.glb')
    run(BIN, SC_MIX + 'delete("Can")\ndelete("Box")\ndelete("Plain")\ndelete(name(1))\nop("file.export_gltf", "%s")' % ref)
    want = open(ref, 'rb').read() if os.path.exists(ref) else b''
    nodes = [n['name'] for n in glb_json(got)['nodes']] if got else []
    check(got is not None and got == want and not gltf_check(got), 'Selected objects only (the file browser): the selected mesh alone, the file of the scene without the others byte for byte (%s)' % nodes)
    r, lg = port('--op', 'script.run %s' % sc, '--op', 'file.export_gltf %s/after.glb' % T)
    n2 = len(glb_json(open('%s/after.glb' % T, 'rb').read())['meshes']) if os.path.exists('%s/after.glb' % T) else 0
    check(n2 == 5, 'and the next export (a script\'s) has every mesh again (%d)' % n2)


# ---- damaged files ------------------------------------------------------------------------

def mutate_json(rng, d):
    """One change somewhere in the document: a number made odd, a key gone, a
    value of another kind, a node tree that cycles, bad base64."""
    paths = []

    def walk(v, path):
        paths.append(path)
        if isinstance(v, dict):
            for k, x in v.items():
                walk(x, path + [k])
        elif isinstance(v, list):
            for k, x in enumerate(v):
                walk(x, path + [k])
    walk(d, [])
    path = rng.choice(paths[1:])
    par = d
    for k in path[:-1]:
        par = par[k]
    k = path[-1]
    r = rng.randrange(10)
    if r == 0 and isinstance(par, dict):
        del par[k]
    elif r == 1:
        par[k] = rng.choice(['x', None, True, [], {}, [1, 2], -0.0])
    elif r == 2 and isinstance(d.get('nodes'), list) and d['nodes'] and all(isinstance(n, dict) for n in d['nodes']):
        n = rng.randrange(len(d['nodes']))
        d['nodes'][n]['children'] = [rng.choice([n, 0, len(d['nodes']) - 1])] + d['nodes'][n].get('children', [])
    elif r == 3 and isinstance(d.get('buffers'), list) and d['buffers'] and isinstance(d['buffers'][0], dict) \
            and isinstance(d['buffers'][0].get('uri'), str) and d['buffers'][0]['uri'].startswith('data:'):
        u = d['buffers'][0]['uri']
        at = rng.randrange(40, len(u))
        d['buffers'][0]['uri'] = u[:at] + rng.choice(['!', '=', '', '====', ';base64,']) + u[at + rng.randrange(3):]
    else:
        par[k] = rng.choice([-1, 0, 1, 2, 3, 4, 7, 2 ** 31 - 1, 2 ** 31, -2 ** 31, 2 ** 32 + 5, 1e10, -1e39, 1e39, 3.7, 65536, 16777217,
                             4294967295, 255, 5120, 5121, 5122, 5123, 5125, 5126, 99999999])
    return d


def damaged(rng, data, glb):
    b = bytearray(data)
    k = rng.randrange(6)
    if k == 0:
        return bytes(b[:rng.randrange(len(b))])
    if k == 1:
        for _ in range(rng.randint(1, 6)):
            b[rng.randrange(len(b))] = rng.randrange(256)
        return bytes(b)
    if k == 2 and glb and len(b) > 28:            # a chunk length or the header made odd
        at = rng.choice([8, 12, 16, 20 + struct.unpack_from('<I', b, 12)[0]])
        if at + 4 <= len(b):
            b[at:at + 4] = struct.pack('<I', rng.choice([0, 1, 7, 0x7fffffff, 0xffffffff, len(b), len(b) - 19]))
        return bytes(b)
    # the JSON changed
    if glb:
        n = struct.unpack_from('<I', b, 12)[0]
        d = json.loads(b[20:20 + n])
    else:
        d = json.loads(b)
    if not isinstance(d, dict):
        return bytes(b)
    for _ in range(rng.randint(1, 3)):
        d = mutate_json(rng, d)
    j = json.dumps(d).encode()
    if not glb:
        return j
    j += b' ' * (-len(j) % 4)
    rest = bytes(b[20 + n:])
    return struct.pack('<III', 0x46546C67, 2, 20 + len(j) + len(rest)) + struct.pack('<II', len(j), 0x4E4F534A) + j + rest


def imports(b, files, timeout):
    """One run: each file imported into an empty scene and saved: {file: .bee bytes or None}, rc."""
    out = os.path.join(T, 'imp-%d' % random.randrange(1 << 30))
    os.makedirs(out)
    code = '\n'.join('op("file.new")\n%sop("file.import_gltf", "%s")\nop("file.save", "%s/%d.bee")' % (CLEAR, q(f), out, k) for k, f in enumerate(files))
    rc, _ = run(b, code, timeout)
    d = {}
    for k, f in enumerate(files):
        p = os.path.join(out, '%d.bee' % k)
        d[f] = p if os.path.exists(p) else None
    return d, rc, out


def s_damage():
    print('-- damaged files --', flush=True)
    rng = random.Random(SEED)
    files = gen()
    srcs = [f for f in files if os.path.basename(f).startswith(('cube', 'types', 'strides', 'textures.g', 'trees', 'random', 'names'))]
    d = os.path.join(T, 'dmg')
    os.makedirs(d, exist_ok=True)
    dm = []
    for k in range(RUNS):
        s = srcs[k % len(srcs)]
        f = os.path.join(d, 'd%d%s' % (k, os.path.splitext(s)[1]))
        open(f, 'wb').write(damaged(rng, open(s, 'rb').read(), s.endswith('.glb')))
        dm.append(f)
    # (a file beside some of them: the textures' image, the external buffers)
    for x in os.listdir(GEN):
        if x.endswith(('.bin', '.png')):
            shutil.copy(os.path.join(GEN, x), d)
    t0 = time.time()
    p, rc, pdir = imports(BIN, dm, 1800)
    tp = time.time() - t0
    nread = sum(1 for f in dm if p[f] is not None)
    check(rc == 0 and nread == len(dm), '%d damaged files imported by the port (debug build): no crash, no hang (rc %d, %.1f s)' % (len(dm), rc, tp))
    bad = [f for f in dm if p[f] is not None and not finite_bee(p[f], finite=False)]
    check(not bad, '%d damaged files: every .bee saved reads back, its indices in range (%s)' % (len(dm), [os.path.basename(f) for f in bad[:4]]))
    shutil.rmtree(pdir, True)
    # made to hurt: cycles, a node its own child, 10^5 roots, deep nesting, a huge count, offsets past views
    g = gltf_gen.G()
    pa, ia = g.positions(gltf_gen.CUBE_P), g.indices(gltf_gen.CUBE_I)
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia}], 'C')
    a0 = g.node(mesh=0, name='A')
    b0 = g.node(root=False, mesh=0, name='B', translation=[0, 1, 0])
    g.d['nodes'][a0]['children'] = [b0, a0]
    g.d['nodes'][b0]['children'] = [a0, b0]
    cyc = os.path.join(d, 'cycle.gltf')
    g.write(cyc)
    hurt = [('a node tree that cycles (A -> B -> A, each its own child)', cyc, 'A B')]
    g2 = json.loads(json.dumps(g.d))
    g2['nodes'] = [{'mesh': 0, 'name': 'n%d' % k, 'children': [k + 1]} for k in range(3000)] + [{'mesh': 0, 'name': 'end'}]
    g2['scenes'] = [{'nodes': [0]}]
    deep = os.path.join(d, 'deep.gltf')
    g.d = g2
    g.write(deep)
    hurt.append(('a chain 3001 nodes deep', deep, 'same'))
    g3 = json.loads(json.dumps(g2))
    g3['nodes'] = [{'children': [k + 1, k + 1]} for k in range(60)] + [{'mesh': 0}]
    lat = os.path.join(d, 'lattice.gltf')
    g.d = g3
    g.write(lat)
    hurt.append(('a lattice: every node twice the child of the one before (2^60 paths)', lat, None))
    g4 = json.loads(json.dumps(g2))
    g4['nodes'] = [{'mesh': 0}]
    g4['scenes'] = [{'nodes': [0] * 100000}]
    wide = os.path.join(d, 'wide.gltf')
    g.d = g4
    g.write(wide)
    hurt.append(('a scene of 100000 roots', wide, 'same'))
    g5 = json.loads(json.dumps(g4))
    g5['scenes'] = [{'nodes': [0]}]
    g5['accessors'][0]['count'] = 2 ** 31 - 1
    g5['accessors'][1]['byteOffset'] = 2 ** 31 - 1
    g5['accessors'][1]['count'] = 1 << 30
    huge = os.path.join(d, 'huge.gltf')
    g.d = g5
    g.write(huge)
    hurt.append(('huge counts and offsets', huge, 'same'))
    open(os.path.join(d, 'nest.gltf'), 'w').write('{"a":' * 70 + '1' + '}' * 70)
    hurt.append(('70 levels of nesting', os.path.join(d, 'nest.gltf'), 'same'))
    g6 = json.loads(json.dumps(g4))
    g6['scenes'] = [{'nodes': [0]}]
    g6['accessors'][0]['byteOffset'] = -2147483000   # (32-bit sums: 2 GB past the view)
    g6['accessors'][0]['count'] = 1
    off = os.path.join(d, 'offset.gltf')
    g.d = g6
    g.write(off)
    hurt.append(('an accessor offset 2 GB past its view', off, None))
    for what, f, names in hurt:
        t0 = time.time()
        rc, so = run(BIN, CLEAR + 'op("file.import_gltf", "%s")\nprint("N", count())\nfor i in 0..count() { print("O", name(i)) }' % f, 120)
        dt = time.time() - t0
        n = [ln.split()[1] for ln in so.splitlines() if ln.startswith('N ')]
        objs = [ln.split()[1] for ln in so.splitlines() if ln.startswith('O ')]
        ok = rc == 0 and n and dt < 60
        extra = ''
        if names == 'same':   # (and the .bee reads back, saved again the same)
            bad, no = import_ok(f)
            ok = ok and not bad
            extra = ', the .bee read back%s' % ('' if not bad else ' but for ' + str(bad[:2]))
        elif names:
            ok = ok and ' '.join(objs) == names
            extra = ', ' + ' '.join(objs)
        check(ok, '%s: no crash, no hang (%.1f s, %s objects%s)' % (what, dt, n[0] if n else '?', extra))


def main():
    only = os.environ.get('GLTF_ONLY', '')
    t0 = time.time()
    for s in (s_import, s_export, s_obj, s_round, s_undo, s_window, s_damage):
        if only and s.__name__ not in only.split(','):
            continue
        try:
            s()
        except Exception as e:  # a crash of the test itself counts
            import traceback
            traceback.print_exc()
            check(False, '%s raised %r' % (s.__name__, e))
    shutil.rmtree(T, True)
    print('gltf: %.0f s, seed %d' % (time.time() - t0, SEED))
    print('fails %d' % len(FAILS))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
