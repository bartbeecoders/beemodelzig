#!/usr/bin/env python3
"""Fixture for src/shgraph_oracle.zig: every shader node type and operation run
through the assembly BeeModel's `nodeval`. Writes tests/files/graph_oracle.bin
(its MATS and MGRF chunks), graph_oracle.txt (mat node k x y z u v value) and
oracle_tex.png. Needs ../BeeModel/build/beemodel."""
import os, random, struct, subprocess, sys, tempfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIG = os.path.join(ROOT, '..', 'BeeModel', 'build', 'beemodel')
OUT = os.path.join(ROOT, 'tests', 'files')
random.seed(20261105)

def png(path, w, h, px):
    raw = b''.join(b'\0' + bytes(c for p in px[y * w:(y + 1) * w] for c in p) for y in range(h))
    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))

tex = os.path.join(OUT, 'oracle_tex.png')
png(tex, 16, 8, [(random.randrange(256), random.randrange(256), random.randrange(256), random.randrange(256)) for _ in range(16 * 8)])

lines = [f'image_name = image("{tex}")'] if False else [f'op("image.load", "{tex}")', 'img = "oracle_tex.png"']
cases = []  # (material, node, outputs) to read
mid = 0

def mat():
    global mid
    n = f'G{mid}'
    mid += 1
    lines.append(f'{n} = material("{n}")')
    return n

class M:
    def __init__(s):
        s.name = mat()
        s.n = 0
    def node(s, typ, *vals):
        s.n += 1
        a = ', '.join([f'"{s.name}"', f'"{typ}"'] + [v if isinstance(v, str) else repr(v) for v in vals])
        lines.append(f'node({a})')
        return s.n
    def link(s, a, b, i, o=0):
        lines.append(f'link("{s.name}", {a}, {b}, {i}, {o})')
    def set(s, n, slot, *v):
        lines.append(f'nodeset("{s.name}", {n}, {slot}, ' + ', '.join(repr(x) for x in v) + ')')
    def read(s, n, outs=1):
        cases.append((s.name, n, outs))

def col():
    return [round(random.uniform(-0.5, 1.5), 3) for _ in range(3)]

m = None
def fresh():
    global m, inputs
    m = M()
    # things to feed: uv, position, a colour noise, values
    inputs = dict(uv=m.node('texcoord', 2.5, 3.5, 0.25, -0.125), pos=m.node('position'), noise=m.node('noise', 3.0, 3.0, 0.5),
                  c=m.node('constant', 0.37), d=m.node('constant', -1.25), e=m.node('constant', 2.75))
    return m

# textures
for wrap in (0, 1, 2):
    for sampler in (0, 1, 2):
        fresh()
        k = m.node('image', '"oracle_tex"', 0.7, sampler, wrap)
        m.link(inputs['uv'], k, 1)
        m.read(k, 5)
        k2 = m.node('image', '"oracle_tex"', 0, sampler, wrap)
        m.read(k2, 5)
        k3 = m.node('textureparam', '"T"')
        m.read(k3, 1)
fresh()
for args in ((4.0, 3.0, 0.5), (1.5, 8.0, 0.7), (0.25, 0.0, 0.2), (9.0, 12.0, 1.0)):
    k = m.node('noise', *args); m.read(k)
    k2 = m.node('noise', *args); m.link(inputs['noise'], k2, 1); m.read(k2)
fresh()
for sc in (2.0, 5.5, 0.3):
    k = m.node('checker', sc); m.set(k, 1, *col()); m.set(k, 2, *col()); m.read(k)
for ax in (0, 1, 2, 3, 4, 7):
    fresh()
    k = m.node('gradient', ax, 1.25, 0.1); m.read(k)
for mode in range(0, 12):
    fresh()
    k = m.node('mix', mode); m.set(k, 2, *col()); m.link(inputs['noise'], k, 3); m.link(inputs['c'], k, 1); m.read(k)
fresh()
k = m.node('ramp', 0.2, 0.8); m.link(inputs['noise'], k, 1); m.set(k, 2, *col()); m.set(k, 3, *col()); m.read(k)
k = m.node('ramp', 0.5, 0.5); m.link(inputs['c'], k, 1); m.read(k)
# math: all, on values that take its edges
for op in range(0, 33):
    fresh()
    for a, b, c in (('c', 'e', 'd'), ('d', 'c', 'e'), ('e', 'd', 'c'), ('noise', 'c', 'e')):
        k = m.node('math', op); m.link(inputs[a], k, 1); m.link(inputs[b], k, 2); m.link(inputs[c], k, 3); m.read(k)
    k = m.node('math', op); m.set(k, 1, 1.0); m.set(k, 2, 0.0); m.read(k)
fresh()
k = m.node('bump', 0.5, 0.02); m.link(inputs['noise'], k, 1); m.read(k)
k = m.node('normalmap', 0.75, 1); m.link(inputs['noise'], k, 1); m.read(k)
# inputs
fresh()
m.read(inputs['uv'], 4); m.read(inputs['pos'], 4)
k = m.node('position', 1); m.read(k, 4)
k = m.node('normal'); m.read(k, 4)
k = m.node('camera'); m.read(k, 4)
k = m.node('vcolor'); m.read(k)
k = m.node('time', 3.0); m.read(k)
k = m.node('color'); m.set(k, 1, *col()); m.read(k)
k = m.node('fresnel', 5.0, 0.04); m.read(k)
k = m.node('fresnel', 2.0, 0.2); m.link(inputs['noise'], k, 1); m.read(k)
for op in range(0, 22):
    fresh()
    k = m.node('vmath', op); m.link(inputs['noise'], k, 1); m.link(inputs['pos'], k, 2); m.link(inputs['c'], k, 3)
    m.read(k, 4 if op in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 15, 16, 17, 18, 19) else 1)
fresh()
k = m.node('separate'); m.link(inputs['noise'], k, 1); m.read(k, 3)
k = m.node('combine'); m.link(inputs['c'], k, 1); m.link(inputs['d'], k, 2); m.link(inputs['e'], k, 3); m.read(k)
k = m.node('mapping', 33.0); m.read(k, 4)
k = m.node('mapping', -120.0); m.link(inputs['pos'], k, 1); m.set(k, 2, 0.3, 0.4, 0.5); m.set(k, 3, 2.0, 3.0, 4.0); m.read(k, 4)
k = m.node('panner', 0.5, -0.25); m.link(inputs['c'], k, 2); m.read(k, 4)
k = m.node('panner', 0.5, -0.25); m.link(inputs['pos'], k, 1); m.link(inputs['e'], k, 2); m.read(k, 4)
k = m.node('rotator', 0.5, 0.5, 0.25); m.link(inputs['c'], k, 2); m.read(k, 4)
for mode in (0, 1, 2):
    for r in (1.0, 0.3):
        fresh()
        k = m.node('voronoi', 5.0, r, mode); m.read(k, 2)
        k = m.node('voronoi', 2.0, r, mode); m.link(inputs['noise'], k, 1); m.read(k, 2)
fresh()
for v in ((0.2, 1.3, 0.7, 1.0), (0.75, 0.5, 1.5, 0.5), (0.0, 0.0, 1.0, 1.0)):
    k = m.node('hsv', *v); m.link(inputs['noise'], k, 1); m.read(k)
    k = m.node('hsv', *v); m.set(k, 1, 0.9, 0.2, 0.2); m.read(k)
    k = m.node('hsv', *v); m.set(k, 1, 0.2, 0.2, 0.9); m.read(k)
fresh()
k = m.node('invert', 0.7); m.link(inputs['noise'], k, 1); m.read(k)
k = m.node('brightcon', 0.2, 0.4); m.link(inputs['noise'], k, 1); m.read(k)
k = m.node('desaturate', 0.6); m.link(inputs['noise'], k, 1); m.read(k)
k = m.node('gamma', 2.2); m.link(inputs['noise'], k, 1); m.read(k)
for K in (800.0, 1500.0, 2500.0, 6500.0, 6600.0, 12000.0):
    k = m.node('blackbody', K); m.read(k)
fresh()
for v in ((4.0, 0.03, 0.5), (7.5, 0.1, 0.25)):
    k = m.node('brick', *v); m.read(k, 2)
    k = m.node('brick', *v); m.link(inputs['pos'], k, 1); m.set(k, 2, *col()); m.read(k, 2)
for v in ((4.0, 0.0, 0, 0), (6.0, 2.0, 1, 0), (3.0, 1.5, 0, 2), (2.0, 0.5, 0, 1)):
    fresh()
    k = m.node('wave', *v); m.read(k, 2)
    k = m.node('wave', *v); m.link(inputs['noise'], k, 1); m.read(k, 2)
fresh()
k = m.node('whitenoise'); m.read(k, 2)
k = m.node('whitenoise'); m.link(inputs['noise'], k, 1); m.read(k, 2)
for s in (0, 1):
    k = m.node('triplanar', 1.0, 0.9, 4.0, s); m.read(k, 2)
k = m.node('reroute'); m.link(inputs['noise'], k, 1); m.read(k)
k = m.node('scalarparam', '"S"', 0.3); m.read(k)
k = m.node('vectorparam', '"V"', 0.1, 0.2, 0.3); m.read(k)
# functions: x -> (x * 2, x + 1, its noise)
lines.append('op("material.function_new", "Fn")')
lines.append('fnm = "Fn"')
fn = 'Fn'
# In 1 is node 1, Out node 2
lines.append(f'node("{fn}", "math", 2)')
lines.append(f'nodeset("{fn}", 3, 2, 2.0)')
lines.append(f'link("{fn}", 1, 3, 1, 0)')   # the nodes sort: the math goes before the output
lines.append(f'link("{fn}", 3, 2, 1, 0)')
fresh()
def call():
    m.n += 1
    lines.append(f'op("material.node", "{m.name} fncall Fn")')
    return m.n
k = call(); m.link(inputs['c'], k, 1); m.read(k, 1)
k2 = call(); m.link(k, k2, 1); m.read(k2, 1)

points = [(0.25, -1.5, 0.75, 0.125, 0.8), (1.0, 2.0, -3.0, 0.5, 0.5), (-0.3, 0.1, 0.77, 2.25, -1.3), (7.1, 13.3, -21.9, 0.0, 1.0), (0.0, 0.0, 0.0, 0.33, 0.66)]
d = tempfile.mkdtemp()
bee = os.path.join(d, 'g.bee')
script = list(lines)
script.append(f'op("file.save", "{bee}")')
sp = os.path.join(d, 'g.bees')
open(sp, 'w').write('\n'.join(script) + '\n')
r = subprocess.run([ORIG, '--run', sp], capture_output=True, text=True)
if r.returncode:
    import re
    w = re.search(r'line (\d+)', r.stdout + r.stderr)
    sys.exit(r.stdout[-2000:] + r.stderr[-2000:] + (script[int(w.group(1)) - 1] if w else ''))
rows = []
head = [f'op("file.open", "{bee}")', 'fn q(m, n, k) {']
for p in points:
    head.append(f'print(nodeval(m, n, k, {p[0]}, {p[1]}, {p[2]}, {p[3]}, {p[4]}) * 10000)')
head.append('}')
calls = []
for name, n, outs in cases:
    for k in range(outs * 4):
        if k >= 4 and k % 4 != 3 and k % 4 != 0:
            continue
        calls.append(f'q("{name}", {n}, {k})')
        for p in points:
            rows.append((name, n, k, p))
vals = []
for i in range(0, len(calls), 200):
    open(sp, 'w').write('\n'.join(head + calls[i:i + 200]) + '\n')
    r = subprocess.run([ORIG, '--run', sp], capture_output=True, text=True)
    got = 0
    for l in r.stdout.split('\n'):
        try:
            vals.append(float(l))
            got += 1
        except ValueError:
            if l.strip() and 'opened' not in l.lower():
                print('?', l)
    if got != len(calls[i:i + 200]) * len(points):
        print(calls[i], got, r.stderr[-300:], r.stdout[-300:])
if len(vals) != len(rows):
    print(r.stdout[-2000:], r.stderr[-2000:])
    sys.exit(f'{len(vals)} values for {len(rows)} rows')

def chunks(path):
    b = open(path, 'rb').read()
    o = 8
    c = {}
    while o + 8 <= len(b):
        t, s = struct.unpack_from('<4sI', b, o)
        if t == b'ZCHK':
            tag, raw = struct.unpack_from('<4sI', b, o + 8)
            c[tag] = zlib.decompress(b[o + 16:o + 8 + s], -15)
        else:
            c[t] = b[o + 8:o + 8 + s]
        o += 8 + s
    return c

c = chunks(bee)
with open(os.path.join(OUT, 'graph_oracle.bin'), 'wb') as f:
    for t in (b'MATS', b'MGRF'):
        f.write(struct.pack('<I', len(c[t])))
        f.write(c[t])
names = {}
with open(os.path.join(OUT, 'graph_oracle.txt'), 'w') as f:
    for (name, n, k, p), v in zip(rows, vals):
        f.write(f'{name} {n} {k} {p[0]} {p[1]} {p[2]} {p[3]} {p[4]} {v / 10000:.10g}\n')
print(len(rows), 'values,', mid, 'materials;', len(c[b'MGRF']), 'bytes of graphs')
