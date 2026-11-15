#!/usr/bin/env python3
"""glTF 2.0 files for tests/gltf.py, written here with json + struct: every
accessor component type (float, normalized u8 / u16 UVs, u8 / u16 / u32
indices), byte strides and interleaving, accessor offsets, sparse accessors,
multiple primitives, non-triangle modes, missing optional fields, TRS and
matrix nodes, deep and wide trees, several scenes, materials with every
extension, alpha modes, textures with KHR_texture_transform, images as
data: URIs, files (with %20) and buffer views (PNG and JPEG), buffers as
data: URIs, files beside the .gltf and a GLB's BIN chunk.

    python3 tests/gltf_gen.py OUTDIR [seed]   -> the files, one per case
"""
import base64, io, json, math, os, random, struct, sys


def png_bytes(w, h, f, mode='RGBA'):
    from PIL import Image
    im = Image.new(mode, (w, h))
    im.putdata([f(x, y) for y in range(h) for x in range(w)])
    b = io.BytesIO()
    im.save(b, 'PNG')
    return b.getvalue()


def jpeg_bytes(w, h, f):
    from PIL import Image
    im = Image.new('RGB', (w, h))
    im.putdata([f(x, y) for y in range(h) for x in range(w)])
    b = io.BytesIO()
    im.save(b, 'JPEG', quality=90)
    return b.getvalue()


class G:
    """A glTF document and its one binary buffer."""

    def __init__(self):
        self.d = {'asset': {'version': '2.0', 'generator': 'gltf_gen'}, 'scene': 0, 'scenes': [{'nodes': []}],
                  'nodes': [], 'meshes': [], 'accessors': [], 'bufferViews': [], 'buffers': []}
        self.bin = bytearray()

    def view(self, data, stride=None, align=4):
        while len(self.bin) % align:
            self.bin.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.bin), 'byteLength': len(data)}
        if stride:
            v['byteStride'] = stride
        self.bin += data
        self.d['bufferViews'].append(v)
        return len(self.d['bufferViews']) - 1

    def acc(self, view, ctype, count, typ, offset=None, **kw):
        a = {'bufferView': view, 'componentType': ctype, 'count': count, 'type': typ}
        if offset is not None:
            a['byteOffset'] = offset
        a.update(kw)
        self.d['accessors'].append(a)
        return len(self.d['accessors']) - 1

    def positions(self, pts, stride=None, pad=0):
        if stride:
            data = b''.join(struct.pack('<3f', *p) + b'\x7f' * (stride - 12) for p in pts)
        else:
            data = b''.join(struct.pack('<3f', *p) for p in pts)
        v = self.view(b'\0' * pad + data, stride)
        lo = [min(p[i] for p in pts) for i in range(3)]
        hi = [max(p[i] for p in pts) for i in range(3)]
        return self.acc(v, 5126, len(pts), 'VEC3', pad if pad else None, min=lo, max=hi)

    def indices(self, idx, ctype=5123):
        fmt = {5121: 'B', 5123: 'H', 5125: 'I'}[ctype]
        return self.acc(self.view(struct.pack('<%d%s' % (len(idx), fmt), *idx)), ctype, len(idx), 'SCALAR')

    def uvs(self, uv, ctype=5126):
        if ctype == 5126:
            data = b''.join(struct.pack('<2f', *t) for t in uv)
        elif ctype == 5123:
            data = b''.join(struct.pack('<2H', *(int(round(max(0, min(1, c)) * 65535)) for c in t)) for t in uv)
        else:
            data = b''.join(struct.pack('<2B', *(int(round(max(0, min(1, c)) * 255)) for c in t)) for t in uv)
        return self.acc(self.view(data), ctype, len(uv), 'VEC2', normalized=ctype != 5126 or None)

    def mesh(self, prims, name=None):
        m = {'primitives': prims}
        if name is not None:
            m['name'] = name
        self.d['meshes'].append(m)
        return len(self.d['meshes']) - 1

    def node(self, root=True, **kw):
        self.d['nodes'].append(kw)
        k = len(self.d['nodes']) - 1
        if root:
            self.d['scenes'][0]['nodes'].append(k)
        return k

    def image(self, data=None, uri=None, mime='image/png', name=None, view=None):
        im = {}
        if name is not None:
            im['name'] = name
        if uri is not None:
            im['uri'] = uri
        elif data is not None:
            im['bufferView'] = self.view(data, align=1)
            im['mimeType'] = mime
        if view is not None:
            im['bufferView'] = view
        self.d.setdefault('images', []).append(im)
        self.d.setdefault('textures', []).append({'source': len(self.d['images']) - 1})
        return len(self.d['textures']) - 1

    def material(self, m):
        self.d.setdefault('materials', []).append(m)
        return len(self.d['materials']) - 1

    def write(self, path, kind='data'):
        """kind: data (a base64 buffer), file (beside it), glb"""
        d = json.loads(json.dumps(self.d))
        if kind == 'glb':
            d['buffers'] = [{'byteLength': len(self.bin)}]
            j = json.dumps(d, separators=(',', ':')).encode()
            j += b' ' * (-len(j) % 4)
            b = bytes(self.bin) + b'\0' * (-len(self.bin) % 4)
            out = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(j) + 8 + len(b))
            out += struct.pack('<II', len(j), 0x4E4F534A) + j + struct.pack('<II', len(b), 0x004E4942) + b
            open(path, 'wb').write(out)
            return
        if kind == 'file':
            bn = os.path.splitext(os.path.basename(path))[0] + '.bin'
            open(os.path.join(os.path.dirname(path), bn), 'wb').write(self.bin)
            d['buffers'] = [{'byteLength': len(self.bin), 'uri': bn}]
        else:
            d['buffers'] = [{'byteLength': len(self.bin),
                             'uri': 'data:application/octet-stream;base64,' + base64.b64encode(bytes(self.bin)).decode()}]
        open(path, 'w').write(json.dumps(d, indent=1))


CUBE_P = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
CUBE_I = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3]


def split_cube():
    """24 corners (4 a face, the positions repeated: they weld), its UVs, indices"""
    pts, uv, idx = [], [], []
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (2, 3, 7, 6), (1, 2, 6, 5), (0, 4, 7, 3)]
    for f in faces:
        b = len(pts)
        for k, v in enumerate(f):
            pts.append(CUBE_P[v])
            uv.append(((k in (1, 2)) * 1.0, (k in (2, 3)) * 1.0))
        idx += [b, b + 1, b + 2, b, b + 2, b + 3]
    return pts, uv, idx


def sphere(n=8, m=6, r=1.0):
    pts, uv, idx = [], [], []
    for j in range(m + 1):
        th = math.pi * j / m
        for i in range(n + 1):
            ph = 2 * math.pi * i / n
            pts.append((r * math.sin(th) * math.cos(ph), r * math.cos(th), r * math.sin(th) * math.sin(ph)))
            uv.append((i / n, j / m))
    for j in range(m):
        for i in range(n):
            a = j * (n + 1) + i
            b = a + n + 1
            idx += [a, b, a + 1, a + 1, b, b + 1]
    return pts, uv, idx


def checker(x, y):
    return (200, 60, 40, 255) if (x // 4 + y // 4) % 2 else (40, 60, 200, 128)


def cases(out, seed=1):
    rng = random.Random(seed)
    files = []

    def put(name, g, kind='data'):
        p = os.path.join(out, name)
        g.write(p, kind)
        files.append(p)

    # 1 a cube: u16 indices, TRS, a material
    g = G()
    pa, ia = g.positions(CUBE_P), g.indices(CUBE_I)
    mt = g.material({'name': 'Red', 'pbrMetallicRoughness': {'baseColorFactor': [0.8, 0.1, 0.1, 1], 'metallicFactor': 0.2,
                                                             'roughnessFactor': 0.7}, 'emissiveFactor': [0.1, 0, 0]})
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia, 'material': mt}], 'm')
    g.node(name='Box', mesh=0, translation=[1, 2, 3], rotation=[0, 0.3826834, 0, 0.9238795], scale=[1, 2, 1])
    put('cube.gltf', g)
    put('cube.glb', g, 'glb')
    put('cube_file.gltf', g, 'file')
    # 2 index types, no indices, modes, a mesh of several primitives, matrix nodes, children
    g = G()
    pa = g.positions(CUBE_P)
    i8, i16, i32 = g.indices(CUBE_I, 5121), g.indices(CUBE_I, 5123), g.indices(CUBE_I, 5125)
    tri = g.positions([CUBE_P[i] for i in CUBE_I])
    mats = [g.material({'name': 'M%d' % k, 'pbrMetallicRoughness': {'baseColorFactor': [k / 4, 0.5, 1 - k / 4, 1]}}) for k in range(3)]
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': i8, 'material': mats[0]},
            {'attributes': {'POSITION': pa}, 'indices': i16, 'material': mats[1], 'mode': 4},
            {'attributes': {'POSITION': pa}, 'indices': i32, 'material': 7},
            {'attributes': {'POSITION': tri}},
            {'attributes': {'POSITION': pa}, 'indices': i16, 'mode': 1},
            {'attributes': {'POSITION': pa}, 'indices': i16, 'mode': 5},
            {'attributes': {'POSITION': pa}, 'indices': i16, 'mode': 0}], 'Many')
    c1 = g.node(root=False, name='Child', mesh=0, translation=[0, 3, 0], scale=[0.5, 0.5, 0.5])
    c2 = g.node(root=False, mesh=0, matrix=[0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 4, 0, 0, 1])
    g.node(name='Parent', mesh=0, rotation=[0, 0, 0.258819, 0.9659258], children=[c1, c2])
    put('types.gltf', g)
    put('types.glb', g, 'glb')
    # 3 strides, interleaving, accessor offsets; UVs float, u8, u16 normalized; few UVs
    g = G()
    pts, uv, idx = split_cube()
    ps = g.positions(pts, stride=24)
    po = g.positions(pts, pad=16)
    ia = g.indices(idx)
    uf, u8, u16 = g.uvs(uv), g.uvs(uv, 5121), g.uvs(uv, 5123)
    short = g.uvs(uv[:10])
    inter = bytearray()
    for p, t in zip(pts, uv):
        inter += struct.pack('<3f2f', *p, *t)
    iv = g.view(bytes(inter), 20)
    pi = g.acc(iv, 5126, len(pts), 'VEC3')
    ti = g.acc(iv, 5126, len(pts), 'VEC2', 12)
    g.mesh([{'attributes': {'POSITION': ps, 'TEXCOORD_0': uf}, 'indices': ia}], 'Strided')
    g.mesh([{'attributes': {'POSITION': po, 'TEXCOORD_0': u8}, 'indices': ia}], 'U8')
    g.mesh([{'attributes': {'POSITION': po, 'TEXCOORD_0': u16}, 'indices': ia}], 'U16')
    g.mesh([{'attributes': {'POSITION': pi, 'TEXCOORD_0': ti}, 'indices': ia}], 'Interleaved')
    g.mesh([{'attributes': {'POSITION': po, 'TEXCOORD_0': short}, 'indices': ia}], 'FewUVs')
    for k in range(5):
        g.node(mesh=k, translation=[k * 3.0, 0, 0])
    put('strides.gltf', g)
    put('strides.glb', g, 'glb')
    # 4 textures: data: URI, a file (with %20), a buffer view (PNG, JPEG); transforms; every map
    g = G()
    pts, uv, idx = sphere()
    pa, ua, ia = g.positions(pts), g.uvs(uv), g.indices(idx)
    p1 = png_bytes(16, 16, checker)
    t_data = g.image(uri='data:image/png;base64,' + base64.b64encode(p1).decode(), name='checker.png')
    open(os.path.join(out, 'my tex.png'), 'wb').write(png_bytes(8, 8, lambda x, y: (x * 30, y * 30, 100, 255), 'RGBA'))
    t_file = g.image(uri='my%20tex.png')
    t_view = g.image(png_bytes(8, 4, lambda x, y: (255, x * 30, y * 60, 255)), name='orm')
    t_jpeg = g.image(jpeg_bytes(16, 8, lambda x, y: (x * 15, 128, y * 30)), mime='image/jpeg', name='photo')
    t_nrm = g.image(png_bytes(4, 4, lambda x, y: (128, 128, 255), 'RGB'))
    t_bad = g.image(b'not an image at all', name='broken')
    m_all = g.material({'name': 'Textured', 'pbrMetallicRoughness': {
        'baseColorTexture': {'index': t_data, 'extensions': {'KHR_texture_transform': {'scale': [2, 3], 'offset': [0.25, 0.5]}}},
        'baseColorFactor': [1, 0.5, 0.5, 0.8], 'metallicFactor': 0.5, 'roughnessFactor': 0.25,
        'metallicRoughnessTexture': {'index': t_view, 'extensions': {'KHR_texture_transform': {'scale': [5, 5], 'offset': [0.1, 0.1]}}}},
        'normalTexture': {'index': t_nrm, 'scale': 0.5}, 'occlusionTexture': {'index': t_view},
        'emissiveTexture': {'index': t_jpeg}, 'emissiveFactor': [1, 0.5, 0], 'alphaMode': 'BLEND'})
    m_file = g.material({'name': 'FromFile', 'pbrMetallicRoughness': {
        'baseColorTexture': {'index': t_file, 'extensions': {'KHR_texture_transform': {'scale': [4, 4]}}}},
        'alphaMode': 'MASK', 'alphaCutoff': 0.3})
    m_bad = g.material({'name': 'Broken', 'pbrMetallicRoughness': {'baseColorTexture': {'index': t_bad}},
                        'occlusionTexture': {'index': 99}, 'emissiveTexture': {'index': t_data, 'texCoord': 1}})
    m_mask = g.material({'name': 'Masked', 'alphaMode': 'MASK', 'pbrMetallicRoughness': {'baseColorTexture': {'index': t_data}}})
    for k, m in enumerate((m_all, m_file, m_bad, m_mask)):
        g.mesh([{'attributes': {'POSITION': pa, 'TEXCOORD_0': ua}, 'indices': ia, 'material': m}], 'S%d' % k)
        g.node(mesh=k, name='Ball%d' % k, translation=[k * 2.5, 0, 0])
    put('textures.gltf', g)
    put('textures.glb', g, 'glb')
    put('textures_file.gltf', g, 'file')
    # 5 materials: every extension, defaults, odd values
    g = G()
    pa, ia = g.positions(CUBE_P), g.indices(CUBE_I)
    ms = [
        {},
        {'name': 'Ext', 'extensions': {'KHR_materials_emissive_strength': {'emissiveStrength': 7.5},
                                       'KHR_materials_transmission': {'transmissionFactor': 0.6},
                                       'KHR_materials_ior': {'ior': 1.33},
                                       'KHR_materials_clearcoat': {'clearcoatFactor': 0.9, 'clearcoatRoughnessFactor': 0.2}},
         'emissiveFactor': [0.5, 0.25, 1]},
        {'name': 'Big', 'pbrMetallicRoughness': {'baseColorFactor': [2, -1, 1e39, 5], 'metallicFactor': -3, 'roughnessFactor': 1e39},
         'extensions': {'KHR_materials_ior': {'ior': 99}, 'KHR_materials_emissive_strength': {'emissiveStrength': 'x'}},
         'emissiveFactor': [0, 0, 0]},
        {'name': 'Short', 'pbrMetallicRoughness': {'baseColorFactor': [0.5, 0.5]}, 'emissiveFactor': [1]},
        {'name': 'MASK', 'alphaMode': 7},
        {'name': 'Cut', 'alphaMode': 'MASK', 'alphaCutoff': 'half'},
        {'name': 'x' * 40, 'alphaMode': 'OPAQUE'},
        {'name': '', 'pbrMetallicRoughness': {}},
        {'name': 'café € \\"q\\"', 'doubleSided': True},
        {'name': 'Red'}, {'name': 'Red'},
    ]
    for k, m in enumerate(ms):
        g.material(m)
        g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia, 'material': k}])
        g.node(mesh=k, translation=[k * 2.5, 0, 0])
    put('materials.gltf', g)
    # 6 scenes: the default one is the second; and a file with none named
    g = G()
    pa, ia = g.positions(CUBE_P), g.indices(CUBE_I)
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia}], 'Cube')
    g.node(mesh=0, name='InFirst')
    g.d['nodes'].append({'mesh': 0, 'name': 'InSecond', 'translation': [0, 5, 0]})
    g.d['nodes'].append({'mesh': 0})
    g.d['scenes'].append({'nodes': [1, 2]})
    g.d['scene'] = 1
    put('scenes.gltf', g)
    g.d['scene'] = -3
    put('scene_neg.gltf', g)
    del g.d['scene']
    put('scene_none.gltf', g)
    # 7 names, welding, degenerate triangles, out of range indices
    g = G()
    pts = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (-0.0, 0, 0), (1, 0, 0), (0, 0, 1), (5, 5, 5)]
    pa = g.positions(pts)
    ia = g.indices([0, 1, 2, 3, 4, 5, 0, 3, 1, 0, 1, 9, 2, 1, 4, 3, 5, 2], 5125)
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia}], 'MeshName')
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia}])
    g.node(mesh=0)
    g.node(mesh=0, name='A very long node name that goes on and on')
    g.node(mesh=1)
    g.node(mesh=1, name=5)
    g.node(mesh=1, name='été€€€€€€€€€€')
    g.node(mesh=1, name='dup')
    g.node(mesh=1, name='dup')
    g.node(mesh=1, name='')
    put('names.gltf', g)
    # 8 trees: more than 32 roots, deep chains, wide children, sparse accessor, cameras and lights
    g = G()
    pa, ia = g.positions(CUBE_P), g.indices(CUBE_I)
    g.mesh([{'attributes': {'POSITION': pa}, 'indices': ia}], 'C')
    for k in range(40):
        g.node(mesh=0, name='R%d' % k, translation=[k, 0, 0])
    prev = None
    for k in range(50):
        n = g.node(root=prev is None, mesh=0 if k % 3 == 0 else None, name='D%d' % k, translation=[0, 0.5, 0],
                   rotation=[0, math.sin(0.05), 0, math.cos(0.05)])
        if prev is not None:
            g.d['nodes'][prev]['children'] = [n]
        prev = n
    kids = [g.node(root=False, mesh=0, name='K%d' % k, translation=[0, 0, k]) for k in range(40)]
    g.node(name='Wide', children=kids)
    sp = g.acc(g.view(struct.pack('<3f', 0, 0, 0) * 8), 5126, 8, 'VEC3', sparse={'count': 1, 'indices': {'bufferView': 0, 'componentType': 5125},
                                                                               'values': {'bufferView': 0}})
    sn = g.acc(None, 5126, 8, 'VEC3')
    del g.d['accessors'][sn]['bufferView']
    g.mesh([{'attributes': {'POSITION': sp}, 'indices': ia}], 'Sparse')
    g.mesh([{'attributes': {'POSITION': sn}, 'indices': ia}], 'NoView')
    g.node(mesh=1)
    g.node(mesh=2)
    g.d['cameras'] = [{'type': 'perspective', 'perspective': {'yfov': 1, 'znear': 0.1}}]
    g.node(camera=0, name='Cam')
    put('trees.gltf', g)
    put('trees.glb', g, 'glb')
    # 9 random meshes and trees
    for r in range(int(os.environ.get('GLTF_RANDOM', '6'))):
        g = G()
        nm = rng.randrange(1, 5)
        for k in range(nm):
            n = rng.randrange(3, 60)
            pts = [tuple(round(rng.uniform(-3, 3), rng.choice([0, 1, 3])) for _ in range(3)) for _ in range(n)]
            nt = rng.randrange(1, 80)
            idx = [rng.randrange(n + (2 if rng.random() < 0.02 else 0)) for _ in range(nt * 3)]
            ct = rng.choice([5121, 5123, 5125]) if n < 250 else rng.choice([5123, 5125])
            pa = g.positions(pts, stride=rng.choice([None, None, 16, 32]), pad=rng.choice([0, 0, 8]))
            prim = {'attributes': {'POSITION': pa}, 'indices': g.indices(idx, ct)}
            if rng.random() < 0.6:
                prim['attributes']['TEXCOORD_0'] = g.uvs([(rng.random(), rng.random()) for _ in range(n)], rng.choice([5126, 5121, 5123]))
            if rng.random() < 0.7:
                prim['material'] = g.material({'name': 'R%d_%d' % (r, k), 'pbrMetallicRoughness': {
                    'baseColorFactor': [rng.random() for _ in range(4)], 'metallicFactor': rng.random(),
                    'roughnessFactor': rng.random()}, 'emissiveFactor': [rng.choice([0, rng.random()]) for _ in range(3)]})
            g.mesh([prim], rng.choice([None, 'mesh%d' % k]))
        nodes = rng.randrange(1, 30)
        for k in range(nodes):
            kw = {}
            if rng.random() < 0.7:
                kw['mesh'] = rng.randrange(nm)
            if rng.random() < 0.5:
                kw['name'] = 'n%d_%d' % (r, k)
            if rng.random() < 0.3:
                a = [rng.uniform(-3, 3) for _ in range(16)]
                a[3] = a[7] = a[11] = 0
                a[15] = 1
                kw['matrix'] = a
            else:
                if rng.random() < 0.7:
                    kw['translation'] = [rng.uniform(-5, 5) for _ in range(3)]
                if rng.random() < 0.6:
                    q = [rng.gauss(0, 1) for _ in range(4)]
                    s = math.sqrt(sum(x * x for x in q))
                    kw['rotation'] = [x / s for x in q]
                if rng.random() < 0.4:
                    kw['scale'] = [rng.uniform(0.2, 3) for _ in range(3)]
            g.node(root=False, **kw)
        # a forest: each node the child of an earlier one or a root
        roots = []
        for k in range(nodes):
            if k == 0 or rng.random() < 0.3:
                roots.append(k)
            else:
                p = rng.randrange(k)
                g.d['nodes'][p].setdefault('children', []).append(k)
        g.d['scenes'][0]['nodes'] = roots
        kind = rng.choice(['data', 'glb', 'file'])
        put('random%d.%s' % (r, 'glb' if kind == 'glb' else 'gltf'), g, kind)
    return files


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for f in cases(out, int(sys.argv[2]) if len(sys.argv) > 2 else 1):
        print(f)
