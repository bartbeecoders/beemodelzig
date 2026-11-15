#!/usr/bin/env python3
"""OBJ and MTL: the export read back (indices in range, numbers finite, the
materials as set), map_* both ways (in, out, in again: the same materials),
damaged and missing MTLs, the export options.

    python3 tests/objmtl.py BIN [runs=60]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
T = tempfile.mkdtemp(prefix='beeobj-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*a):
    ui = f'{T}/u.txt'
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=120)
    return r, open(ui, errors='replace').read() if os.path.exists(ui) else ''


def script(code, what):
    r = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=120)
    check(r.returncode == 0, f'{what}: the script ran (exit {r.returncode})')
    return r


def objfile(path):
    """(objects, vertices, faces as index lists, ok): every index in range, every number finite."""
    v, f, o, ok = [], [], [], True
    nvt = nvn = 0
    for ln in open(path).read().split('\n'):
        w = ln.split()
        if not w:
            continue
        if w[0] == 'o':
            o.append(' '.join(w[1:]))
        elif w[0] in ('v', 'vt', 'vn'):
            try:
                xs = [float(c) for c in w[1:]]
            except ValueError:
                return o, v, f, False
            ok &= all(math.isfinite(x) for x in xs) and len(xs) >= (2 if w[0] == 'vt' else 3)
            if w[0] == 'v':
                v.append(tuple(xs[:3]))
            elif w[0] == 'vt':
                nvt += 1
            else:
                nvn += 1
        elif w[0] == 'f':
            face = []
            for c in w[1:]:
                parts = c.split('/')
                face.append(int(parts[0]))
                ok &= 1 <= int(parts[0]) <= len(v)
                ok &= len(parts) < 2 or not parts[1] or 1 <= int(parts[1]) <= nvt
                ok &= len(parts) < 3 or not parts[2] or 1 <= int(parts[2]) <= nvn
            ok &= len(face) >= 3
            f.append(face)
    return o, v, f, ok


def mtlfile(path):
    """{newmtl: {key: rest of the line}}."""
    out, cur = {}, None
    for ln in open(path).read().split('\n'):
        w = ln.split(None, 1)
        if not w or w[0].startswith('#'):
            continue
        if w[0] == 'newmtl':
            cur = out.setdefault(w[1] if len(w) > 1 else '', {})
        elif cur is not None:
            cur[w[0]] = w[1] if len(w) > 1 else ''
    return out


def nums(t):
    return [float(x) for x in t.split()]


def mats(path):
    """MATS as (name, the 96 bytes after it) per material."""
    b = beefile.chunk(path, b'MATS')
    n = struct.unpack_from('<I', b)[0]
    rec = (len(b) - 4) // n if n else 0
    return [(b[4 + k * rec:4 + k * rec + 32].split(b'\0')[0].decode(), struct.unpack_from('<14f', b, 4 + k * rec + 32)) for k in range(n)]


def graph(path):
    return beefile.chunk(path, b'MGRF')


# --- the export, read back ---------------------------------------------------------
base = 'op("material.new", "Red"); op("material.assign", "Red"); op("material.set", "Red base 1 0 0"); op("material.set", "Red roughness 0.3"); op("material.set", "Red metallic 0.7")'
os.makedirs(f'{T}/pp')
script(f'select("Cube"); {base}; add("sphere", "S", 3, 0, 0); op("file.save", "{T}/s.bee")', 'the scene')
r, ui = port('--op', f'file.open {T}/s.bee', '--op', f'file.export_obj {T}/pp/o.obj', '--wait', '10')
check(r.returncode == 0 and os.path.exists(f'{T}/pp/o.obj') and os.path.exists(f'{T}/pp/o.mtl'), 'OBJ and MTL written')
o_, v_, f_, ok = objfile(f'{T}/pp/o.obj')
check(ok and sorted(o_) == ['Cube', 'S'] and len(v_) > 8 and len(f_) > 6, f'OBJ reads back: objects {o_}, {len(v_)} vertices, {len(f_)} faces, indices in range, numbers finite')
t = open(f'{T}/pp/o.obj').read()
check('mtllib o.mtl' in t and 'usemtl Red' in t, 'OBJ: mtllib o.mtl, usemtl Red')
m = mtlfile(f'{T}/pp/o.mtl').get('Red', {})
check(m and nums(m.get('Kd', '')) == [1, 0, 0] and abs(nums(m.get('Pr', 'nan'))[0] - 0.3) < 1e-5 and abs(nums(m.get('Pm', 'nan'))[0] - 0.7) < 1e-5,
      f'MTL: Red as set (Kd {m.get("Kd")}, Pr {m.get("Pr")}, Pm {m.get("Pm")})')
r, ui = port('--op', f'file.open {T}/s.bee', '--op', f'file.export_obj {T}/pp/o2.obj')
check(open(f'{T}/pp/o2.obj').read() == t.replace('o.mtl', 'o2.mtl') and open(f'{T}/pp/o2.mtl').read() == open(f'{T}/pp/o.mtl').read(), 'exported twice: the same files')
os.makedirs(f'{T}/rt')
r, ui = port('--op', f'file.import_obj {T}/pp/o.obj', '--op', f'file.export_obj {T}/rt/o.obj')
o2, v2, f2, ok2 = objfile(f'{T}/rt/o.obj')
check(r.returncode == 0 and ok2 and len(v2) >= len(v_) and len(f2) >= len(f_) and 'Red' in mtlfile(f'{T}/rt/o.mtl'),
      f'imported and exported again: {len(v2)} vertices, {len(f2)} faces, Red still there')

# --- map_*, in -----------------------------------------------------------------------
Image.new('RGB', (8, 8), (200, 100, 50)).save(f'{T}/base.png')
Image.new('RGB', (8, 8), (0, 120, 200)).save(f'{T}/orm.png')
Image.new('RGB', (8, 8), (128, 128, 255)).save(f'{T}/nrm.png')
Image.new('RGB', (8, 8), (255, 0, 0)).save(f'{T}/em.png')
Image.new('L', (8, 8), 200).save(f'{T}/mask.png')
tri = 'v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n'
cases = {
    'kd': ('newmtl M\nKd 0.1 0.2 0.3\nNs 100\nd 0.5\nmap_Kd base.png\n', ''),
    'set': ('newmtl M\nPr 0.2\nNs 100\nmap_Kd base.png\nnorm nrm.png\nmap_Ke em.png\nmap_d mask.png\n', ''),
    'orm': ('newmtl M\nKd 1 1 1\nmap_Pr -imfchan g orm.png\nmap_Pm -imfchan b orm.png\n', ''),
    'two': ('newmtl A\nKd 1 0 0\nTr 0.25\nKe 0.5 0.5 0.5\nNi 1.5\nTf 0.1 0.2 0.3\nPm 0.5\nPc 0.25\nPcr 0.125\nnewmtl B\nKd 0 1 0\nmap_Kd base.png\n', 'usemtl B\n'),
}
for name, (mtl, use) in cases.items():
    d = f'{T}/{name}'
    os.makedirs(d)
    for f in ('base', 'orm', 'nrm', 'em', 'mask'):
        os.link(f'{T}/{f}.png', f'{d}/{f}.png')
    open(f'{d}/m.mtl', 'w').write(mtl)
    open(f'{d}/x.obj', 'w').write('mtllib m.mtl\n' + (use or 'usemtl M\n') + tri)
    p = f'{d}/p.bee'
    r, ui = port('--op', f'file.import_obj {d}/x.obj', '--op', f'file.save {p}')
    check(r.returncode == 0 and os.path.exists(p), f'{name}: imported and saved')
    if not os.path.exists(p):
        continue
    mb = mats(p)
    want = [ln.split(None, 1)[1] for ln in mtl.split('\n') if ln.startswith('newmtl ')]
    check(all(n in [x[0] for x in mb] for n in want) and all(math.isfinite(v) for x in mb for v in x[1]),
          f'{name}: the MTL\'s materials, every value finite: {[x[0] for x in mb]}')
    gb = graph(p)
    check(('map_' not in mtl and 'norm' not in mtl) or len(gb or b'') > 0, f'{name}: the maps make a graph ({len(gb or b"")} bytes)')
    check('x' in {x['name'] for x in beefile.objects(p)}, f'{name}: the object x')
    cb = struct.unpack_from('<I', beefile.chunk(p, b'OMAT'), 4 + 3 * 4)[0]
    check(cb > 0, f'{name}: its material on the object ({cb})')
# missing and hostile files
d = f'{T}/bad'
os.makedirs(d)
open(f'{d}/m.mtl', 'w').write('Kd 1 1 1\nmap_Kd nothere.png\nnewmtl \nnewmtl ' + 'x' * 500 + '\nKd nan inf 1e99\nmap_Kd\nmap_Kd /nonexistent/a.png\nNs -5\nd\nTr x\n')
open(f'{d}/x.obj', 'w').write('mtllib m.mtl\nusemtl nothere\n' + tri)
r, ui = port('--op', f'file.import_obj {d}/x.obj')
check(r.returncode == 0 and '4 objects' in ui, 'a hostile MTL: the mesh still comes in')
open(f'{d}/y.obj', 'w').write('mtllib gone.mtl\n' + tri)
r, ui = port('--op', f'file.import_obj {d}/y.obj')
check(r.returncode == 0 and '4 objects' in ui, 'no MTL: the mesh still comes in')

# damaged MTLs: bytes changed anywhere, a mesh always comes in
import random
rng = random.Random(3)
seed = open(f'{T}/two/m.mtl', 'rb').read() + open(f'{T}/set/m.mtl', 'rb').read()
d = f'{T}/fz'
os.makedirs(d)
for f in ('base', 'orm', 'nrm', 'em', 'mask'):
    os.link(f'{T}/{f}.png', f'{d}/{f}.png')
open(f'{d}/x.obj', 'w').write('mtllib m.mtl\nusemtl M\n' + tri)
bad = 0
for k in range(int(sys.argv[3]) if len(sys.argv) > 3 else 60):
    b_ = bytearray(seed)
    for _ in range(rng.randrange(1, 30)):
        b_[rng.randrange(len(b_))] = rng.choice([0, 10, 32, 255, 46, 45, 48, rng.randrange(256)])
    open(f'{d}/m.mtl', 'wb').write(b_)
    r, ui = port('--op', f'file.import_obj {d}/x.obj', '--op', f'file.save {d}/o.bee')
    if r.returncode != 0 or '4 objects' not in ui:
        bad += 1
        print(r.stderr[-300:])
        break
check(bad == 0, 'damaged MTLs: no crash, the mesh comes in')

# --- map_*, out --------------------------------------------------------------------
for name, keys in (('kd', ['map_Kd']), ('set', ['map_Kd', 'norm', 'map_Ke']), ('orm', ['map_Pr -imfchan g', 'map_Pm -imfchan b'])):
    d = f'{T}/{name}'
    if not os.path.exists(f'{d}/p.bee'):
        check(False, f'{name}: no scene to export')
        continue
    os.makedirs(f'{d}/e')
    r, ui = port('--op', f'file.open {d}/p.bee', '--op', f'file.export_obj {d}/e/pe.obj')
    b = open(f'{d}/e/pe.mtl').read() if os.path.exists(f'{d}/e/pe.mtl') else ''
    check(r.returncode == 0 and all(k in b for k in keys), f'{name}: the MTL with its maps {keys}')
    files = [ln.split()[-1] for ln in b.split('\n') if ln.startswith(('map_', 'norm', 'bump'))]
    check(files and all(os.path.exists(os.path.join(f'{d}/e', x)) for x in files), f'{name}: its maps\' files there {files}')
    if name == 'kd':
        k = mtlfile(f'{d}/e/pe.mtl').get('M', {})
        check(all(abs(a - b_) < 1e-5 for a, b_ in zip(nums(k.get('Kd', '9 9 9')), (0.1, 0.2, 0.3))), f'{name}: Kd as it came in ({k.get("Kd")})')
    # in again and out again: the same MTL
    r, ui = port('--op', f'file.import_obj {d}/e/pe.obj', '--op', f'file.save {d}/e/q.bee', '--op', f'file.export_obj {d}/e/qe.obj')
    q = open(f'{d}/e/qe.mtl').read() if os.path.exists(f'{d}/e/qe.mtl') else ''
    check(r.returncode == 0 and q == b, f'{name}: imported and exported again: the same MTL')
    if q != b:
        print(b[-400:], '\n----\n', q[-400:])
    check(os.path.exists(f'{d}/e/q.bee') and len(graph(f'{d}/e/q.bee') or b'') > 0, f'{name}: and a graph again')

# --- options ------------------------------------------------------------------------
s = f'{T}/s.bee'
OUT = '/tmp/beemodel-headless/BeeModel'
os.makedirs(OUT, exist_ok=True)


def browser(op, name, *choices):
    """Export through the file browser's options."""
    p = f'{OUT}/{name}'
    if os.path.exists(p):
        os.unlink(p)
    r, ui = port('--op', f'file.open {s}', '--op', 'select S', '--op', op, *choices, '--click-label', 'button:Save')
    check(r.returncode == 0 and os.path.exists(p), f'{op}: through the file browser')
    return p, ui


plain = [tuple(float(c) for c in l.split()[1:4]) for l in open(f'{T}/pp/o.obj').read().split('\n') if l.startswith('v ')]
p, ui = browser('file.export_obj', 'scene.obj', '--click-label', 'checkbox:Selected objects only')
t = open(p).read()
check(t.count('\no ') == 1 and '\no S' in t, 'Selected objects only: the sphere alone')
sv = [tuple(float(c) for c in l.split()[1:4]) for l in t.split('\n') if l.startswith('v ')]
check(sv and sv == plain[-len(sv):] and len(sv) < len(plain), f'  its {len(sv)} vertices as they were')
num = re.search(r'number\t1\t(-?\d+) (-?\d+) (\d+) (\d+)', open(f'{T}/u.txt', errors='replace').read())
r, ui = port('--op', f'file.open {s}', '--op', 'file.export_obj')
x, y, w, h = [int(v) for v in [l for l in ui.split('\n') if l.startswith('number\t')][-1].split('\t')[2].split()]
p, ui = browser('file.export_obj', 'scene.obj', '--click-label', 'button:Z', '--click', f'{x + w // 2},{y + h // 2}', '--key', 'ctrl+a', '--type', '1000', '--key', 'enter')
zv = [tuple(float(c) for c in l.split()[1:4]) for l in open(p).read().split('\n') if l.startswith('v ')]
check(len(zv) == len(plain) and all(abs(a[0] - b[0] * 1000) < 2e-2 and abs(a[1] + b[2] * 1000) < 2e-2 and abs(a[2] - b[1] * 1000) < 2e-2 for a, b in zip(zv, plain)), 'Z up, scale 1000: (x, -z, y) in millimetres')
# one export only: the next is plain again
r, ui = port('--op', f'file.open {s}', '--op', f'file.export_obj {T}/after.obj')
check(open(f'{T}/after.obj').read().count('\no ') == 2, 'scripts: the defaults')
stl = f'{T}/a.stl'
r, ui = port('--op', f'file.open {s}', '--op', f'file.export_stl {stl}')
n = struct.unpack_from('<I', open(stl, 'rb').read(), 80)[0]
sd = open(stl, 'rb').read()
tris = sum(len(x) - 2 for x in f_)
check(len(sd) == 84 + 50 * n and n == tris, f'STL: {n} triangles, as many as the OBJ\'s faces make ({tris}), the file that long')
check(all(math.isfinite(x) for k in range(n) for x in struct.unpack_from('<12f', sd, 84 + 50 * k)), 'STL: every number finite')
p, ui = browser('file.export_stl', 'scene.stl', '--click-label', 'checkbox:Selected objects only', '--click-label', 'button:Z')
d = open(p, 'rb').read()
nb = struct.unpack_from('<I', d, 80)[0]
check(nb < n, f'STL: the options too ({nb} triangles)')
# hidden objects go too
r, ui = port('--op', f'file.open {s}', '--op', 'select S', '--move', '615,360', '--key', 'h', '--op', f'file.export_obj {T}/h.obj')
check(open(f'{T}/h.obj').read().count('\no ') == 2, 'hidden objects are exported')
print(f'objmtl: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
