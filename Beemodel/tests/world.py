#!/usr/bin/env python3
"""World partition (world.zig), standalone:

  * make: a 32 x 32 map of 50 m cells, 4096 objects, partitioned and
    streamed around the camera (WORLD_BEES here): 1024 cells, every one
    written, each cell file whole (BEEC, its chunks to the end, 4 objects);
    made twice, the same output and the same files chunk for chunk;
  * stream: a flight under a memory budget, edits (a prop carried into a
    cell not loaded, one deleted, one added), away and back, saved and
    opened again: the edits go to their cells and come back; run twice, the
    same statistics, objects (in their order) and files;
  * ops: world.partition (unsaved, bad sizes, again with another size, off),
    world.radius, world.budget (huge, tiny), world(k), Save As (the cells
    move along), file.new: unsaved and bad sizes refused; twice the same;
  * land: landscape.tiles streamed out and back in with their heights;
  * damaged: cell files truncated, flipped, garbage, empty, missing, bad
    headers, huge counts, bad meshes; stray names in the folder; a damaged
    WRLP: no crash, the world goes on, the damage reaches what is loaded;
  * window: BeeModel in the fake compositor (tests/wl_fake.py), over MCP:
    opened with its world, streaming in the window's loop under a budget,
    undo after edits and after streaming, the minimap's pixels and the
    unloaded cells' boxes, world.partition off brings every cell back;
  * panel: the Render tab's World Partition section;
  * perf: making the world and a flight (WORLD_REL: a release build), timed.

    python3 tests/world.py BIN [damage-runs=20] [seed]

BEE_CPU (default 14) pins every run; WORLD_ONLY=bees,stream,ops,land,damaged,window,panel,perf
runs some (bees always runs when another needs its world); WORLD_REL=<release
build> for perf (else perf measures BIN).
"""
import json, os, random, re, shutil, socket, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '14')
ONLY = [x for x in os.environ.get('WORLD_ONLY', '').split(',') if x]
REL = os.environ.get('WORLD_REL', '')
FAILS = []
T = tempfile.mkdtemp(prefix='beeworld-', dir='/tmp')
PROCS = []


def want(sec):
    return not ONLY or sec in ONLY


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def home(tag):
    h = tempfile.mkdtemp(prefix=tag + '-', dir=T)
    for sub in ('.cache', '.config', '.local/share', '.local/state', 'run', 'BeeModel'):
        os.makedirs(os.path.join(h, sub), exist_ok=True)
    os.chmod(os.path.join(h, 'run'), 0o700)
    return h


def env_of(h):
    e = dict(os.environ, HOME=h, XDG_CACHE_HOME=f'{h}/.cache', XDG_CONFIG_HOME=f'{h}/.config', XDG_DATA_HOME=f'{h}/.local/share',
             XDG_STATE_HOME=f'{h}/.local/state', XDG_RUNTIME_DIR=f'{h}/run', BEEMODEL_GPU='off')
    e.pop('WAYLAND_DISPLAY', None)
    e.pop('DISPLAY', None)
    return e


def run(binary, h, code, timeout=900):
    """BeeScript in a program (--run), HOME h: (return code, output)."""
    p = os.path.join(h, 's.bees')
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary, '--run', p], capture_output=True, text=True, errors='replace', timeout=timeout, env=env_of(h))
    except subprocess.TimeoutExpired:
        return -999, 'hung'
    return r.returncode, r.stdout + r.stderr


LIB = '''fn st() {
  s = ""
  for j in 0..14 { s = s + " " + str(world(j)) }
  return s + " n" + str(count())
}
fn names() {
  s = ""
  for i in 0..count() { s = s + name(i) + "," }
  return s
}
'''


# ---- the files ---------------------------------------------------------------------------

def cell(path):
    d = open(path, 'rb').read()
    if len(d) < 16:
        return None
    magic, ver, x, z = struct.unpack_from('<IIii', d)
    out, o = [], 16
    while len(d) - o >= 8:
        t, s = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        out.append((t, d[o + 8:o + 8 + s]))
        o += 8 + s
    return magic, ver, x, z, out, len(d) - o


def norm_celo(c):
    """CELO with the bytes after each name's (and material name's) NUL zeroed."""
    n = struct.unpack_from('<I', c)[0] if len(c) >= 4 else 0
    out = bytearray(c)
    for k in range(n):
        o = 4 + k * 120
        if o + 120 > len(out):
            break
        for a, b in ((o, o + 32), (o + 88, o + 120)):
            z = bytes(out[a:b]).find(b'\0')
            if z >= 0:
                out[a + z:b] = b'\0' * (b - a - z)
    return bytes(out)


def norm_land(c):
    """LAND with each block's reference count and evaluation time zeroed (as tests/landio.py)."""
    out, o = bytearray(c), 0
    while len(c) - o >= 8:
        nb = struct.unpack_from('<I', c, o + 4)[0]
        if nb >= 76 and o + 8 + nb <= len(c):
            out[o + 8:o + 12] = b'\0' * 4
            out[o + 8 + 72:o + 8 + 76] = b'\0' * 4
        o += 8 + nb
    return bytes(out)


def cell_diff(a, b):
    if os.path.isdir(a) or os.path.isdir(b):
        return None if os.path.isdir(a) and os.path.isdir(b) else 'a folder'
    if open(a, 'rb').read() == open(b, 'rb').read():
        return None
    A, B = cell(a), cell(b)
    if A is None or B is None:
        return None if A == B else 'short'
    if A[:4] + A[5:] != B[:4] + B[5:]:
        return 'header'
    if [t for t, _ in A[4]] != [t for t, _ in B[4]]:
        return 'chunks %s / %s' % (b' '.join(t for t, _ in A[4]).decode(), b' '.join(t for t, _ in B[4]).decode())
    for (t, x), (_, y) in zip(A[4], B[4]):
        if t == b'CELO':
            x, y = norm_celo(x), norm_celo(y)
        if t == b'LAND':
            x, y = norm_land(x), norm_land(y)
        if x != y:
            return '%s differs (%d / %d bytes)' % (t.decode(), len(x), len(y))
    return None


def dirs_diff(a, b):
    fa = sorted(os.listdir(a)) if os.path.isdir(a) else []
    fb = sorted(os.listdir(b)) if os.path.isdir(b) else []
    if fa != fb:
        return [('files', f'{len(fa)} / {len(fb)}: {sorted(set(fa) ^ set(fb))[:6]}')]
    return [(f, d) for f in fa for d in [cell_diff(os.path.join(a, f), os.path.join(b, f))] if d]


def wrlp(path):
    c = beefile.chunk(path, b'WRLP')
    if c is None:
        return None
    n = struct.unpack_from('<I', c, 16)[0]
    head = c[:20]
    recs = []
    for k in range(n):
        r = bytearray(c[20 + k * 76:20 + (k + 1) * 76])
        r[12:20] = b'\0' * 8      # the fingerprint
        r[52:64] = b'\0' * 12     # the fingerprint now, how many now (when last drawn)
        recs.append(bytes(r))
    return head, recs, len(c)


SCENE_CHUNKS = (b'OBJS', b'UIDS', b'PRNT', b'OMAT', b'VIEW')


def scene_diff(a, b):
    """The scene files' object chunks (OBJS's mesh indices left out: primitives
    share a mesh)."""
    ca, cb = dict(beefile.chunks(a)), dict(beefile.chunks(b))
    bad = []
    for t in SCENE_CHUNKS:
        x, y = ca.get(t), cb.get(t)
        if t == b'OBJS' and x and y:
            ox, oy = beefile.objects(a), beefile.objects(b)
            strip = lambda L: [{k: v for k, v in o.items() if k != 'mesh'} for o in L]
            if strip(ox) != strip(oy):
                bad.append(t)
        elif x != y:
            bad.append(t)
    if wrlp(a) != wrlp(b):
        bad.append(b'WRLP')
    return bad


def files_same(label, ho, hp, name):
    d = dirs_diff(f'{ho}/BeeModel/{name}.cells', f'{hp}/BeeModel/{name}.cells')
    n = len(os.listdir(f'{ho}/BeeModel/{name}.cells')) if os.path.isdir(f'{ho}/BeeModel/{name}.cells') else 0
    check(not d, f'{label}: the {n} cell files the same, chunk for chunk' + (f' ({len(d)} differ: {d[:3]})' if d else ''))
    if os.path.exists(f'{ho}/BeeModel/{name}.bee') and os.path.exists(f'{hp}/BeeModel/{name}.bee'):
        s = scene_diff(f'{ho}/BeeModel/{name}.bee', f'{hp}/BeeModel/{name}.bee')
        w = wrlp(f'{ho}/BeeModel/{name}.bee')
        check(not s, f'{label}: the scene file\'s {"/".join(t.decode() for t in SCENE_CHUNKS)} and WRLP ({len(w[1]) if w else 0} cells) the same' + (f' (differ: {s})' if s else ''))


def cells_ok(h, name, per=None):
    """Every cell file whole: BEEC, version 1, its chunks to the end, a CELO
    (of `per` objects): (cells, objects, the bad ones)."""
    d = f'{h}/BeeModel/{name}.cells'
    bad, n, nobj = [], 0, 0
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        n += 1
        c = cell(os.path.join(d, f))
        celo = [b for t, b in c[4] if t == b'CELO'] if c else []
        k = struct.unpack_from('<I', celo[0])[0] if celo and len(celo[0]) >= 4 else -1
        if c is None or c[0] != 0x43454542 or c[1] != 1 or c[5] != 0 or k < 0 or (per is not None and k != per) or f != f'{c[2]}_{c[3]}.cell':
            bad.append(f)
        nobj += max(k, 0)
    return n, nobj, bad


def twice(label, code, src=None, name='world', timeout=900, files=True):
    """The code run in two homes (each a copy of src's world): the same
    output, and (files) the same cell and scene files. The first output."""
    ha, hb = (copy_world(src, 'ta'), copy_world(src, 'tb')) if src else (home('ta'), home('tb'))
    a, b = run(BIN, ha, code, timeout), run(BIN, hb, code, timeout)
    check(a[0] == 0 and a == b, f'{label}: ran cleanly, twice the same output ({len(a[1].splitlines())} lines)' +
          ('' if a == b else '\n      ' + '\n      '.join(f'{x[:160]!r} / {y[:160]!r}' for x, y in zip(a[1].splitlines(), b[1].splitlines()) if x != y)[:900]))
    if files:
        files_same(label, ha, hb, name)
    return a, ha, hb


# ---- make: a world written while partitioned ------------------------------------------------

WORLD = {}
# a 32 x 32 map of 50 m cells, 4 props each (Prop_<x>_<z>_<k> at x = (x - 16) * 50 + 10 + 10 k)
WORLD_BEES = LIB + '''delete("Cube")
for zi in 0..32 {
  for xi in 0..32 {
    for k in 0..4 {
      add("cube", "Prop_" + str(xi) + "_" + str(zi) + "_" + str(k), (xi - 16) * 50 + 10 + 10 * k, 1, (zi - 16) * 50 + 25)
    }
  }
}
op("file.save", "~/BeeModel/world.bee")
op("world.partition", "50 150")
print("part", st())
view(45, 22, 90, 0, 25, 0)
op("world.update")
op("world.update")
op("file.save", "~/BeeModel/world.bee")
print("world", st())
'''


def s_bees():
    print('-- a 32 x 32 map of 50 m cells, 4096 props, partitioned and streamed --')
    t0 = time.time()
    a, ha, hb = twice('the world made', WORLD_BEES)
    v = {ln.split()[0]: ln.split()[1:] for ln in a[1].splitlines() if ' ' in ln}
    check(v.get('part', [''] * 10)[:3] == ['1', '1024', '1024'] and v.get('part', [''] * 10)[9] == '4096',
          f'partitioned: 1024 cells, all loaded, 4096 props in them ({v.get("part")})')
    w = v.get('world', [''] * 8)
    check(w[:2] == ['1', '1024'] and w[5] == '1024' and 0 < int(float(w[2] or 0)) < 1024,
          f'streamed around the camera: 1024 cells, every one written, {w[2]} loaded ({w})')
    n, nobj, bad = cells_ok(ha, 'world', 4)
    check(n == 1024 and nobj == 4096 and not bad, f'{n} cell files, each whole with its 4 props ({nobj} in all; bad {bad[:4]})')
    print(f'     ({time.time() - t0:.1f} s for both)')
    WORLD['port'] = ha
    shutil.rmtree(hb, True)


def need_world():
    if 'port' not in WORLD:
        s_bees()


def copy_world(src, tag):
    h = home(tag)
    shutil.rmtree(f'{h}/BeeModel')
    shutil.copytree(f'{src}/BeeModel', f'{h}/BeeModel')
    return h


# ---- stream: flying over a world, edits ------------------------------------------------------

FLY = LIB + '''op("file.open", "~/BeeModel/world.bee")
print("open", st())
op("world.budget", "8")
op("world.radius", "150")
for k in 0..12 {
  view(30 + 7 * k, 22, 90, -700 + 120 * k, 25, -600 + 100 * k)
  op("world.update")
  print("fly", k, st())
}
print(names())
op("world.budget", "3")
op("world.update")
print("budget", st())
print(names())
'''

EDIT = LIB + '''op("file.open", "~/BeeModel/world.bee")
op("world.budget", "8")
op("world.radius", "150")
view(45, 22, 90, 0, 25, 0)
op("world.update")
print("home", st())
print(names())
move("Prop_16_16_0", 325, 30, 325)
delete("Prop_16_16_1")
add("cube", "Marker", 10, 30, 10)
scale("Marker", 4)
print("edits", st())
op("world.update")
print("upd", st(), exists("Prop_16_16_0"))
view(200, 22, 90, 700, 25, -700)
op("world.update")
print("far", st(), exists("Marker"), exists("Prop_16_16_0"))
view(45, 22, 90, 0, 25, 0)
op("world.update")
print("back", st(), get("Marker", "x"), exists("Prop_16_16_1"), get("Prop_16_16_2", "x"))
print(names())
view(45, 22, 90, 325, 25, 325)
op("world.update")
print("there", st(), get("Prop_16_16_0", "x"))
op("file.save", "~/BeeModel/world.bee")
print("saved", st())
op("file.open", "~/BeeModel/world.bee")
print("open", st())
op("world.update")
print("upd2", st(), get("Prop_16_16_0", "x"))
'''


def s_stream():
    print('-- streaming: a flight and edits --')
    need_world()
    for nm, code in (('a flight under an 8 MB budget', FLY), ('edits carried, deleted, added; away and back; saved, opened', EDIT)):
        a, ha, hb = twice(nm, code, WORLD['port'], files=code is EDIT)
        lines = a[1].strip().splitlines()
        if code is FLY:
            fl = [ln.split()[1:] for ln in lines if ln.startswith('fly ')]
            ok = fl and all(float(x[4]) <= float(x[5]) + 0.01 for x in fl) and len({x[3] for x in fl}) > 1
            check(ok and len(fl) == 12, f'the flight: 12 places, the loaded cells within the budget at each, cells coming and going ({[x[3] for x in fl]})')
        else:
            v = {ln.split()[0]: ln.split()[1:] for ln in lines if ln and ln[0].islower() and ' ' in ln}
            check(v.get('there', [''])[-1] == '325' and v.get('back', [''] * 4)[-3:] == ['10', '0', '30'] and v.get('far', [''])[-2:] == ['0', '0']
                  and v.get('upd2', [''])[-1] == '325',
                  f'the edits went to their cells and came back, saved and opened again ({v.get("far", [])[-2:]}, {v.get("back", [])[-3:]}, {v.get("there", [])[-1:]}, {v.get("upd2", [])[-1:]})')
            n, nobj, bad = cells_ok(ha, 'world')
            check(n >= 1024 and not bad, f'the cell files whole after the edits ({n}, bad {bad[:3]})')
        shutil.rmtree(ha, True)
        shutil.rmtree(hb, True)


# ---- ops: the operators' edges --------------------------------------------------------------

OPS = LIB + '''print("w", world(99), world(-1), world(14), world(2.7))
op("world.partition", "10")
print("unsaved", st())
op("file.save", "~/BeeModel/a.bee")
op("world.partition", "0")
op("world.partition", "-3")
op("world.partition", "abc")
op("world.partition", "")
op("world.radius", "")
op("world.budget", "x")
print("bad", st())
for i in 0..20 { add("cube", "C" + str(i), i * 7 - 60, 0, i * 3 - 20) }
add("sphere", "S", 3, 1, 3)
m = modifier("S", "subsurf")
add("cylinder", "AVeryLongNameForAPropThatGoesOn", 4, 0, 4)
add("cylinder", "AVeryLongNameForAPropThatGoes", 6, 0, 6)
set("C3", "rx", 0.7)
set("C4", "sy", 2.5)
material("Red")
assign("C5", "Red")
op("world.partition", "10 25")
print("on", st())
view(45, 22, 5, 50, 0, 0)
op("world.update")
print("u1", st(), names())
op("world.partition", "20")
print("re", st(), names())
view(45, 22, 5, -50, 0, 0)
op("world.update")
print("u2", st(), names())
op("world.radius", "0.2")
op("world.update")
print("r", st(), names())
op("world.budget", "1e30")
print("b", st())
op("world.budget", "0.5")
print("b2", st())
op("world.budget", "512")
op("world.radius", "1000")
op("world.update")
print("u3", st(), names(), get("C3", "rx"), get("C4", "sy"), get("AVeryLongNameForAPropThatG", "x"), get("AVeryLongNameForAPropThatG.001", "x"))
op("world.radius", "5")
view(45, 22, 5, 0, 0, 0)
op("world.update")
op("file.save_as", "~/BeeModel/b.bee")
print("saveas", st(), names())
op("world.radius", "1000")
op("world.update")
print("all", st(), names())
op("world.partition", "off")
print("off", st(), names())
op("world.partition", "off")
op("file.save", "~/BeeModel/b.bee")
op("file.open", "~/BeeModel/a.bee")
print("a", st(), names())
op("world.update")
print("a2", st(), names())
op("file.new")
print("new", st())
op("world.minimap")
print("mini", st())
'''


def s_ops():
    print('-- the operators: sizes, radius, budget, again, off, Save As, world(k) --')
    a, ho, hp = twice('the operators', OPS, files=False)
    lines = a[1].strip().splitlines()
    v = {ln.split()[0]: ln.split()[1:] for ln in lines if ln and ' ' in ln}
    check(v.get('unsaved', [''])[0] == '0' and v.get('bad', [''])[0] == '0' and v.get('on', [''])[:2] == ['1', '18'],
          f'unsaved and bad sizes refused, then 18 cells of 10 m ({v.get("on", [])[:3]})')
    check(v.get('off', [''])[0] == '0' and v.get('new', [''])[0] == '0', f'off, and file.new: no partition ({v.get("off", [])[:1]}, {v.get("new", [])[:1]})')
    for nm in ('a', 'b'):
        files_same(f'{nm}.cells', ho, hp, nm)
    n, _, bad = cells_ok(ho, 'b')
    check(not bad, f'b.cells whole ({n} left once the partition went off)')
    shutil.rmtree(ho, True)
    shutil.rmtree(hp, True)


# ---- land: landscape tiles streamed --------------------------------------------------------

LAND = '''delete("Cube")
op("landscape.add", "res 1025 size 400")
h = height("Landscape", 30, -40)
op("landscape.tiles", "4")
op("file.save", "~/BeeModel/wp.bee")
op("world.partition", "100 150")
view(45, 22, 90, 2000, 25, 2000)
op("world.update")
op("world.update")
far = 0
for i in 0..count() { if landscape(name(i), 0) != nil { far = far + 1 } }
view(45, 22, 90, 0, 25, 0)
for k in 0..20 { op("world.update") }
near = 0
hh = -1
for i in 0..count() { if landscape(name(i), 0) != nil { near = near + 1
  v = height(name(i), 30, -40)
  if v != nil { hh = v } } }
print("stream", far, near, hh - h, world(1), world(2), world(5), world(6), world(7))
'''


def s_land():
    print('-- landscape tiles: out and back in through their cells (LAND) --')
    a, ho, hp = twice('landscape tiles', LAND, name='wp')
    w = a[1].split()
    check(a[0] == 0 and len(w) > 3 and w[1] == '0' and int(w[2]) > 0 and abs(float(w[3])) < 1e-5,
          f'the tiles stream out and back with their heights: {a[1].strip()!r}')
    shutil.rmtree(ho, True)
    shutil.rmtree(hp, True)


# ---- damaged: cell files and the index ------------------------------------------------------

SMALL = LIB + '''for i in 0..24 { add("cube", "C" + str(i), (i % 6) * 9 - 25, 0, floor(i / 6) * 9 - 15) }
for i in 0..6 { add("sphere", "S" + str(i), i * 11 - 30, 2, 5) }
op("file.save", "~/BeeModel/d.bee")
op("world.partition", "10 30")
view(45, 22, 5, 500, 0, 500)
op("world.update")
op("file.save", "~/BeeModel/d.bee")
print("made", st())
'''

USE = LIB + '''op("file.open", "~/BeeModel/d.bee")
print("open", st())
op("world.radius", "1000")
op("world.update")
print("in", st(), names())
add("cube", "New", 1, 0, 1)
if exists("C7") { move("C7", 2, 0, 2) }
view(45, 22, 5, 900, 0, 900)
op("world.radius", "10")
op("world.update")
print("out", st(), names())
op("world.radius", "1000")
view(45, 22, 5, 0, 0, 0)
op("world.update")
print("back", st(), names())
op("file.save", "~/BeeModel/d.bee")
op("file.open", "~/BeeModel/d.bee")
op("world.update")
print("again", st(), names())
'''


def damage(rng, path, kind):
    d = bytearray(open(path, 'rb').read())
    if kind == 'truncate':
        d = d[:rng.randrange(len(d))]
    elif kind == 'flip':
        for _ in range(rng.randrange(1, 9)):
            d[rng.randrange(len(d))] ^= 1 << rng.randrange(8)
    elif kind == 'garbage':
        d = bytearray(rng.randbytes(rng.randrange(1, 4000)))
    elif kind == 'garbage-after-header':
        d = d[:16] + bytearray(rng.randbytes(rng.randrange(1, 4000)))
    elif kind == 'empty':
        d = bytearray()
    elif kind == 'magic':
        d[0] ^= 0x20
    elif kind == 'version':
        d[4] = 2
    elif kind == 'chunk-size':
        struct.pack_into('<I', d, 20, 0xfffffff0)
    elif kind in ('celo-count', 'celo-mesh', 'celo-type', 'celo-long-name', 'mesh-offsets', 'mesh-loop', 'mesh-counts', 'mesh-spare-loops'):
        o = 16
        while o + 8 <= len(d):
            t, s = bytes(d[o:o + 4]), struct.unpack_from('<I', d, o + 4)[0]
            if kind.startswith('celo') and t == b'CELO':
                if kind == 'celo-count':
                    struct.pack_into('<I', d, o + 8, 0xffffffff)
                elif kind == 'celo-long-name':
                    d[o + 12:o + 12 + 32] = b'ALongerNameThanTwentySixBytesXY\0'
                elif kind == 'celo-mesh':
                    struct.pack_into('<I', d, o + 12 + 80, 999)
                else:
                    struct.pack_into('<I', d, o + 12 + 72, 1)
            if kind.startswith('mesh') and t == b'MESH':
                nv, np_, nl = struct.unpack_from('<III', d, o + 8)
                if kind == 'mesh-offsets' and np_ > 1:
                    struct.pack_into('<I', d, o + 20 + nv * 12 + 4, nl + 5)
                elif kind == 'mesh-loop' and nl > 0:
                    struct.pack_into('<I', d, o + 20 + nv * 12 + (np_ + 1) * 4, nv + 3)
                elif kind == 'mesh-counts':
                    struct.pack_into('<I', d, o + 8, 0x2000000)
                elif kind == 'mesh-spare-loops' and np_ > 0:   # (the last polygon short: loops left over, unused)
                    struct.pack_into('<I', d, o + 20 + nv * 12 + np_ * 4, nl - 1)
                break
            o += 8 + s
    elif kind == 'nan':
        o = 16
        while o + 8 <= len(d):
            t, s = bytes(d[o:o + 4]), struct.unpack_from('<I', d, o + 4)[0]
            if t == b'CELO':
                struct.pack_into('<f', d, o + 12 + 32, float('nan'))
            o += 8 + s
    if kind == 'missing':
        os.remove(path)
    else:
        open(path, 'wb').write(bytes(d))


CELL_KINDS = ['truncate', 'flip', 'garbage', 'garbage-after-header', 'empty', 'missing', 'magic', 'version', 'chunk-size',
              'celo-count', 'celo-mesh', 'celo-type', 'celo-long-name', 'mesh-offsets', 'mesh-loop', 'mesh-counts', 'mesh-spare-loops']


def rewrite_wrlp(path, fn):
    out = b'BEEM' + struct.pack('<I', 1)
    for t, c in beefile.chunks(path):
        if t == b'WRLP':
            c = fn(bytearray(c))
            if c is None:
                continue
        out += t + struct.pack('<I', len(c)) + bytes(c)
    open(path, 'wb').write(out)


def wrlp_kinds():
    def n_big(c):
        struct.pack_into('<I', c, 16, struct.unpack_from('<I', c, 16)[0] + 1)
        return c
    def setf(off, v):
        def f(c):
            struct.pack_into('<f', c, off, v)
            return c
        return f
    def budget0(c):
        struct.pack_into('<Q', c, 8, 0)
        return c
    def stray_cell(c):
        struct.pack_into('<ii', c, 20, 7, 7)   # an index entry with no file
        return c
    def n_wrap(c):
        struct.pack_into('<I', c, 16, 56512728)   # x 76 = 2^32 + 32: a 32-bit size check would pass
        return c
    return [('a count past the chunk', n_big), ('a count whose size wraps 32 bits', n_wrap), ('cut to 19 bytes', lambda c: c[:19]), ('cut inside the records', lambda c: c[:20 + 76 * 2 + 30]),
            ('a cell size of 0', setf(0, 0.0)), ('a negative radius', setf(4, -5.0)), ('a budget of 0', budget0),
            ('an index entry without a file', stray_cell), ('no WRLP', lambda c: None)]


def s_damaged():
    print(f'-- damaged cell files, folders and indexes (seed {SEED}, {RUNS} random) --')
    rng = random.Random(SEED)
    base = home('dbase')
    r = run(BIN, base, SMALL)
    check(r[0] == 0 and 'made' in r[1], f'a small world: {r[1].strip()!r}')
    cells = sorted(os.listdir(f'{base}/BeeModel/d.cells'))
    hb = copy_world(base, 'db')
    plain = run(BIN, hb, USE, 300)
    shutil.rmtree(hb, True)
    bit = 0
    cases = [(k, rng.choice(cells)) for k in CELL_KINDS] + [(rng.choice(['truncate', 'flip', 'garbage', 'garbage-after-header']), rng.choice(cells)) for _ in range(RUNS)]
    crashed = 0
    for kind, victim in cases + [('stray', None), ('nan', cells[0])] + [(nm, fn) for nm, fn in wrlp_kinds()]:
        hp = copy_world(base, 'dp')
        rr = random.Random(hash((SEED, kind, str(victim))) & 0xffffffff)
        if kind == 'stray':
            cd = f'{hp}/BeeModel/d.cells'
            for nm in ('a_b.cell', '1_2.cell.bak', '-_1.cell', '99999999999_1.cell', '3_4.cel', '4_-1.cellx', '0_x.cell', '--2_1.cell'):
                open(os.path.join(cd, nm), 'wb').write(b'x')
            os.makedirs(os.path.join(cd, '5_5.cell'), exist_ok=True)
            shutil.copy(os.path.join(cd, cells[0]), os.path.join(cd, '-9_-9.cell'))
        elif callable(victim):
            rewrite_wrlp(f'{hp}/BeeModel/d.bee', victim)
        else:
            damage(rr, f'{hp}/BeeModel/d.cells/{victim}', kind)
        b = run(BIN, hp, USE, 300)
        ok_bee = True
        try:
            beefile.objects(f'{hp}/BeeModel/d.bee')
        except Exception:
            ok_bee = False
        shutil.rmtree(hp, True)
        label = kind if not callable(victim) else 'WRLP: ' + kind
        if b[0] != 0 or 'panic' in b[1] or b[0] == -999 or 'again' not in b[1] or not ok_bee:
            crashed += 1
            check(False, f'{label} ({victim if not callable(victim) else ""}): BeeModel stopped or did not go on ({b[0]}): {b[1][-300:]!r}')
            continue
        if kind == 'nan':
            # (a NaN place: read as 0, as a .bee file's)
            check('back' in b[1], f'a NaN place in a cell: read as 0, the world goes on ({b[1].splitlines()[1][:80] if len(b[1].splitlines()) > 1 else b[1][:80]!r})')
            continue
        bit += b != plain
    n = len(cases) + 2 + len(wrlp_kinds())
    check(not crashed, f'{n} damaged worlds: BeeModel never stopped, went on to the end, the scene saved reads back')
    check(bit >= n * 2 // 3, f'{bit} of them change what is loaded from the undamaged world\'s (the damage reaches the cells)')


# ---- window: both programs in their fake compositors -----------------------------------------

class Prog:
    """BeeModel in the fake compositor, an MCP client on its socket."""

    def __init__(self, h, args=()):
        self.home = h
        env = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0'}
        from wl_fake import Fake
        env.update(env_of(h), XDG_RUNTIME_DIR=h)
        self.f = Fake(BIN, size=(1280, 800), env=env, args=args)
        self.f.until(lambda: self.f.frames > 0, 10)
        PROCS.append(self)
        os.sched_setaffinity(self.f.proc.pid, {int(CPU)})
        self.pump(0.3)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(60):
            try:
                self.s.connect(os.path.join(h, 'beemodel.sock'))
                break
            except OSError:
                self.pump(0.1)
        self.s.setblocking(False)
        self.buf = b''
        self.seq = 0

    def pump(self, t=0.05):
        self.f.pump(t)

    def call(self, method, params=None, timeout=20.0):
        self.seq += 1
        m = {'jsonrpc': '2.0', 'id': self.seq, 'method': method}
        if params is not None:
            m['params'] = params
        self.s.sendall((json.dumps(m, separators=(',', ':')) + '\n').encode())
        end = time.time() + timeout
        while time.time() < end:
            while b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get('id') == self.seq:
                    return line.decode('utf-8', 'replace')
            self.pump(0.01)
            try:
                c = self.s.recv(1 << 22)
                if c == b'':
                    return None
                self.buf += c
            except BlockingIOError:
                pass
        return None

    def tool(self, name, args=None):
        r = self.call('tools/call', {'name': name, 'arguments': args or {}})
        try:
            res = json.loads(r)['result']
            return res['content'][0]['text'], res.get('isError'), r
        except (TypeError, ValueError, KeyError, IndexError):
            return None, None, r

    def bs(self, code):
        return (self.tool('script_eval', {'code': code})[0] or '').strip()

    def image(self):
        from PIL import Image
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def settle(self, secs=8):
        """Pumps until no cells wait (world(13) is 0) and a frame came."""
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.05)
            if self.bs('print(world(13))') == '0':
                break
        self.pump(0.3)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            self.f.proc.kill()
            self.f.proc.wait()
        except Exception:
            pass


def norm(r, h):
    """A reply with the temp HOME and the request's id made alike."""
    return None if r is None else re.sub(r'^\{"jsonrpc":"2.0","id":\d+,', '{"jsonrpc":"2.0","id":0,', r.replace(h, '$HOME'))


def minimap(img):
    """The minimap's square (its 0x1d2027 background, 172 px) and what is in it, or None."""
    px = img.load()
    w, h = img.size
    for y in range(h - 1, h - 400, -1):
        for x in range(w - 1, w - 500, -1):
            if px[x, y] == (0x1d, 0x20, 0x27) and px[x - 171, y] == (0x1d, 0x20, 0x27) and px[x, y - 171] == (0x1d, 0x20, 0x27):
                return img.crop((x - 171, y - 171, x + 1, y + 1))
    return None


def s_window():
    print('-- the window: BeeModel in the fake compositor, over MCP --')
    need_world()
    hp = copy_world(WORLD['port'], 'wp')
    P = Prog(hp)
    try:
        def tool(label, name, args):
            r = P.tool(name, args)
            check(r[2] is not None and r[0] is not None, label + f' ({(r[0] or "")[:120]!r})')
            return r
        # the operators' replies, before a file is open (unsaved)
        for arg in ('', '0', '-3', 'abc', '10'):
            tool(f'run_operator world.partition "{arg}" on an unsaved scene: a reply', 'run_operator', {'id': 'world.partition', 'arg': arg})
        check(P.bs('print(world(0))') == '0', 'and no partition made')
        # (agents may not open files: the world opened as started, beemodel world.bee)
        P.close()
        P = Prog(hp, (f'{hp}/BeeModel/world.bee',))
        P.pump(1.0)
        a = P.bs(LIB + 'print(st())')
        check(a.startswith('1 1024'), f'opened (beemodel world.bee): partitioned, 1024 cells ({a!r})')
        P.bs('op("world.budget", "8")\nop("world.radius", "150")\nview(45, 22, 90, 0, 25, 0)')
        P.settle()
        st = LIB + 'print(st())\nprint(names())'
        a = P.bs(st)
        check(a.count(',') > 10 and P.bs('print(world(13))') == '0', f'streamed in the window\'s loop around the camera: cells and objects in, none waiting ({a.splitlines()[0] if a else a!r})')
        # undo after streaming: the history started afresh
        tool('undo after streaming: a reply', 'undo', {})
        check(P.bs(st) == a, '  ... and nothing from before the cells came in undone')
        # fly: the window's loop (two cells a pass), the budget
        for k, (yaw, x, z) in enumerate([(30, -300, -250), (60, 200, -100), (120, 500, 400), (45, 0, 0)]):
            P.bs(f'view({yaw}, 22, 90, {x}, 25, {z})')
            P.settle()
            w = P.bs('print(world(13), world(3) <= world(4), world(2))').split()
            check(w[:2] == ['0', 'true'] or w[:2] == ['0', '1'], f'flown to ({x}, {z}): none waiting, the loaded cells within the budget ({w})')
        # undo around streaming: an edit, then an operator of the world that streams nothing
        x0 = P.bs('print(get("Prop_16_16_2", "x"))')
        for k, (mid, arg) in enumerate((('', ''), ('world.update', ''), ('world.radius', '150'), ('world.budget', '8'), ('world.minimap', ''))):
            P.bs(f'move("Prop_16_16_2", {k + 3}, 33, 4)')
            P.pump(0.2)
            if mid:
                tool(f'run_operator {mid} "{arg}" after an edit: a reply', 'run_operator', {'id': mid, 'arg': arg})
                P.pump(0.3)
            tool(f'undo after an edit{" and " + mid if mid else ""}: a reply', 'undo', {})
            got = P.bs('print(get("Prop_16_16_2", "x"))')
            check(got == x0, f'  ... and the prop where it was ({got} / {x0})')
            if mid == 'world.minimap':
                tool('run_operator world.minimap back on', 'run_operator', {'id': 'world.minimap'})
        # an edit, then streaming: the history starts afresh
        P.bs('move("Prop_16_16_2", 9, 33, 4)')
        P.pump(0.2)
        P.bs('view(45, 22, 90, 300, 25, 0)')
        P.settle()
        before = P.bs(LIB + 'print(st())')
        tool('undo after an edit and streaming: a reply', 'undo', {})
        check(P.bs(LIB + 'print(st())') == before, '  ... the world as streamed (the history began again)')
        P.bs('view(45, 22, 90, 0, 25, 0)')
        P.settle()
        # the minimap and the boxes: from above
        P.bs('view(40, 40, 420, 0, 20, 0)')
        P.settle()
        P.bs('move("Prop_20_20_2", 236, 33, 220)')   # (a changed cell near the eye: orange)
        P.pump(1.0)
        ip = P.image()
        ip.save(os.path.join(os.environ.get('WORLD_SHOTS', T), 'win.png'))
        mp = minimap(ip)
        if mp is not None:
            pp = list(mp.getdata())
            cols = {c: pp.count(c) for c in ((0x4c, 0x52, 0x5c), (0x3e, 0x9b, 0x52), (0xe5, 0xa3, 0x3b), (0xff, 0xff, 0xff), (0xd0, 0xd4, 0xdc))}
            check(cols[(0xe5, 0xa3, 0x3b)] > 0 and cols[(0x4c, 0x52, 0x5c)] > 0 and cols[(0x3e, 0x9b, 0x52)] > 0,
                  f'the minimap: cells on disk, loaded and changed, the camera, its radius ({cols})')
        else:
            check(False, 'the minimap is drawn')
        bp = sum(1 for c in ip.getdata() if c == (0x55, 0x5b, 0x66))
        check(bp > 500, f'the cells not loaded drawn as boxes: {bp} pixels of 0x555b66')
        tool('run_operator world.minimap: a reply', 'run_operator', {'id': 'world.minimap'})
        P.pump(0.5)
        check(minimap(P.image()) is None, 'world.minimap hides it')
        tool('run_operator world.minimap again: a reply', 'run_operator', {'id': 'world.minimap'})
        # the operators on a partitioned scene (the camera and the light go first)
        P.bs('delete("Camera")\ndelete("Light")')
        for op_, arg in (('world.radius', '120'), ('world.budget', '64'), ('world.update', ''), ('world.partition', '25'), ('world.partition', 'off'), ('world.partition', 'off')):
            tool(f'run_operator {op_} "{arg}": a reply', 'run_operator', {'id': op_, 'arg': arg})
            P.pump(0.3)
        a = P.bs(LIB + 'print(st())')
        check(a.startswith('0 ') and a.endswith('n4096'), f'off: every cell back in, 4096 props ({a!r})')
        tool('undo after the partition went off: a reply', 'undo', {})
        check(P.f.proc.poll() is None, 'the window still running')
    finally:
        P.close()
        shutil.rmtree(hp, True)


# ---- panel: the Render tab's World Partition section (the port's own layout) ----------------------

def s_panel():
    print('-- the Render tab\'s World Partition panel (rnui.s: its widgets, what they run) --')
    h = home('pn')

    def shot(*args):
        for f in ('u.txt', 'log.txt'):
            if os.path.exists(f'{h}/{f}'):
                os.remove(f'{h}/{f}')
        subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{h}/a.ppm', '--size', '1280x1600', '--click-label', 'tab:Render', '--wait', '100', *args,
                        '--dump-ui', f'{h}/u.txt', '--dump-log', f'{h}/log.txt'], capture_output=True, env=env_of(h), timeout=300)
        u = open(f'{h}/u.txt').read() if os.path.exists(f'{h}/u.txt') else ''
        lg = open(f'{h}/log.txt').read() if os.path.exists(f'{h}/log.txt') else ''
        return u, lg
    u, lg = shot()
    want_ = ['heading\tWorld Partition', 'checkbox\tPartition the world', 'number\tCell size (m)', 'number\tLoading radius (m)', 'number\tMemory (MB)', 'checkbox\tMinimap', 'button\tUpdate Now']
    check(all(w in u for w in want_), 'the panel: Partition the world, Cell size, Loading radius, Memory, Minimap, Update Now')
    u, lg = shot('--click-label', 'checkbox:Partition the world')
    check('World partition: save the scene first (its cells are kept beside it)' in lg, 'Partition the world on an unsaved scene: "save the scene first"')
    u, lg = shot('--op', f'file.save_as {h}/BeeModel/p.bee', '--click-label', 'checkbox:Partition the world')
    check('World partition: cells of 64 m, 1 cells' in lg and os.path.isdir(f'{h}/BeeModel/p.cells') is False,
          'Partition the world on a saved scene: "cells of 64 m, 1 cells" (the cube\'s cell, loaded: no file yet)')
    shutil.rmtree(h, True)


# ---- perf: release builds ----------------------------------------------------------------

def s_perf():
    binary = REL or BIN
    print(f'-- timings: {"the release build" if REL else "BIN (set WORLD_REL to a release build)"} --')
    res = {}
    best = 1e9
    h = None
    for _ in range(3):
        if h:
            shutil.rmtree(h, True)
        h = home('pf')
        t = time.time()
        r = run(binary, h, WORLD_BEES)
        best = min(best, time.time() - t)
    res['bees'] = best
    check(r[0] == 0, 'the world made')
    h2 = copy_world(h, 'pfy')
    shutil.rmtree(h, True)
    h = h2
    best = 1e9
    for _ in range(3):
        t = time.time()
        r = run(binary, h, FLY.replace('print(names())', ''))
        best = min(best, time.time() - t)
    res['fly'] = best
    check(r[0] == 0, 'the flight flown')
    shutil.rmtree(h, True)
    for k in ('bees', 'fly'):
        print(f'     {k}: {res[k] * 1000:.0f} ms')


def main():
    t0 = time.time()
    try:
        for name, fn in (('bees', s_bees), ('stream', s_stream), ('ops', s_ops), ('land', s_land), ('damaged', s_damaged), ('window', s_window), ('panel', s_panel), ('perf', s_perf)):
            if want(name):
                fn()
    finally:
        for p in PROCS:
            p.close()
        shutil.rmtree(T, True)
    print(f'world: {time.time() - t0:.0f} s, fails {len(FAILS)}')
    for f in FAILS:
        print('   ', f)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
