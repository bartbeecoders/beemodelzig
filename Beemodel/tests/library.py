#!/usr/bin/env python3
"""The content library (library.zig), assets (asset.zig) and the Asset
Browser, BeeModel on its own:

  * s_save: every kind saved from one scene (objects with their materials,
    one evaluated through a modifier, several at once, a node tree with
    nested groups, a rig with its skinned mesh, an action, a whole scene; one
    object twice under two names, one again: tags merged), tags added and
    taken away, an asset removed: index.txt's lines well formed, every blob
    named by the hash of its bytes (stored once), the scene blob a .bee file,
    tree.save_asset / material.save_asset's .beea files, lib.pack's packs
    (each blob once); saved a second time from the same scene: the same
    index.txt and blobs.
  * s_cross: placed from the library (Gate with its materials first, the rig
    bound again, an object evaluated, a material on the selection, a tree, an
    action on the active object): where they land, their materials, meshes
    and weights as in the scene they came from; asset.load of the .beea
    files; lib.import of the packs into an empty library: the same library
    back (twice: nothing doubles).
  * s_damaged: index.txt damaged (bad ids, kinds, hex, too many dependencies,
    missing fields, long lines, the same id twice): read and written back
    well formed, and the same file the next time; damaged blobs placed and
    damaged .beea files loaded and damaged packs imported: no crash, the
    scene saved reads back, no blob under a wrong hash.
  * s_undo: placing is one undo step: undo leaves the scene as before (the
    viewport shows it), redo puts it back.
  * s_thumbs: lib.thumbnails path-traces the missing thumbnails in child
    processes: one 128 x 128 PNG for each, not blank.
  * s_window: the Asset Browser (maximized): tiles with thumbnails, a
    selected tile's details, a search, nothing found, the empty library, more
    assets than fit, all drawn; a double-click places at the 3D cursor, a
    tile dragged into a viewport lands on the surface under the pointer, the
    tile menu.
  * s_time: a library of 1000 assets: reading it, searching it, listing it,
    the browser's frame (the times printed), a release build pinned to one CPU.
  * s_fuzz: random damage and random operations: no crash, no hang.

    python3 tests/library.py BIN [runs=1]

BEE_CPU (default 18) pins BeeModel; LB_ONLY=s_save,... runs some;
LB_REL=path: a release build for the timing (else BIN).
"""
import os, pwd, random, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '18')
ONLY = [x for x in os.environ.get('LB_ONLY', '').split(',') if x]
REL = os.environ.get('LB_REL', BIN)
FAILS = []
T = tempfile.mkdtemp(prefix='beelib-', dir='/tmp')
M64 = (1 << 64) - 1


def _real_home():
    return pwd.getpwuid(os.getuid()).pw_dir


def _real_state():
    """The user's real ~/BeeModel and ~/.config/beemodel{,-zig}: names, sizes,
    times (read only; the real home found by uid, temphome moved HOME)."""
    h = _real_home()
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel', 'BeeModel'):
        top = os.path.join(h, d)
        for root, dirs, files in os.walk(top):
            for n in dirs + files:
                p = os.path.join(root, n)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                out[os.path.relpath(p, h)] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_state()


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def lbhash(b, seed=0):
    """library.s's lb_hash: 8 bytes a step, FNV-like, finalized."""
    h = 0xcbf29ce484222325 ^ seed
    p = 0x100000001b3
    i, n = 0, len(b)
    while n - i >= 8:
        h ^= int.from_bytes(b[i:i + 8], 'little')
        h = (h * p) & M64
        h ^= h >> 32
        i += 8
    while i < n:
        h ^= b[i]
        h = (h * p) & M64
        i += 1
    h ^= n
    h = (h * 0x9e3779b97f4a7c15) & M64
    h ^= h >> 31
    return h


def home(name):
    h = os.path.join(T, name)
    shutil.rmtree(h, True)
    os.makedirs(os.path.join(h, 'BeeModel'))
    return h


def script(h, code, timeout=600):
    """BeeModel runs a BeeScript file with HOME h: (return code, stdout)."""
    p = os.path.join(h, 's.bees')
    open(p, 'w').write(code + '\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout,
                           env=dict(os.environ, HOME=h, XDG_CACHE_HOME=''))
    except subprocess.TimeoutExpired:
        return 'timeout', ''
    return r.returncode, r.stdout


def port(h, *a, binary=None, timeout=600):
    """The port, headless, HOME h: (return code, its console log)."""
    lg = os.path.join(h, 'log.txt')
    if os.path.exists(lg):
        os.remove(lg)
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', os.path.join(h, 'u.ppm'), '--dump-log', lg, *a],
                           capture_output=True, text=True, timeout=timeout, env=dict(os.environ, HOME=h, XDG_CACHE_HOME=''))
    except subprocess.TimeoutExpired:
        return 'timeout', ''
    if r.returncode != 0:
        print(r.stderr[-1500:])
    return r.returncode, open(lg, errors='replace').read() if os.path.exists(lg) else ''


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def steps_port(steps):
    out = []
    for kind, s in steps:
        out += ['--select', s] if kind == 'sel' else ['--op', s]
    return out


def lib_dir(h):
    return os.path.join(h, 'BeeModel', 'library')


def index(h):
    p = os.path.join(lib_dir(h), 'index.txt')
    return open(p).read() if os.path.exists(p) else None


def blobs(h):
    d = os.path.join(lib_dir(h), 'blobs')
    return {f: open(os.path.join(d, f), 'rb').read() for f in sorted(os.listdir(d))} if os.path.isdir(d) else {}


def rd(p):
    return open(p, 'rb').read() if os.path.exists(p) else None


# ---- the scene the library is saved from -------------------------------------------------------------

MAKE = '''material("Gold")
matset("Gold", "base", 1, 0.77, 0.34)
matset("Gold", "metallic", 1)
matset("Gold", "roughness", 0.25)
material("Clay")
matset("Clay", "base", 0.75, 0.38, 0.22)
assign("Cube", "Gold")
add("cylinder", "Pillar", 3, 1, 0)
scale("Pillar", 0.5, 1, 0.5)
assign("Pillar", "Clay")
add("sphere", "Orb", -3, 1, 0)
modifier("Orb", "subsurf")
assign("Orb", "Gold")
t0 = gtree("Pad")
t = gtree("Steps")
o = gnode(t, "output")
g = gnode(t, "grid", 4, 8)
glink(t, g, o, 1)
t2 = gtree("Inner")
o2 = gnode(t2, "output")
c2 = gnode(t2, "cube", 1.5)
glink(t2, c2, o2, 1)
t3 = gtree("Deep")
o3 = gnode(t3, "output")
gp = gnode(t, "group", 3)
gq = gnode(t2, "group", 4)
add("cylinder", "Limb", 0, 1, 4)
scale("Limb", 0.3, 1, 0.3)
a = armature("Rig")
move("Rig", 0, 0, 4)
op("arm.parent", "Limb Rig")
key("Cube:x", 1, 0)
key("Cube:x", 25, 4)
key("Cube:ry", 1, 0)
key("Cube:ry", 25, 3.14)
select("Cube")
op("anim.action", "Spin")
'''

SAVE = [('sel', 'Cube'), ('op', 'lib.save object GoldBox #metal #box'),
        ('sel', 'Pillar'), ('op', 'lib.save object Pillar #stone #column'),
        ('sel', 'Orb'), ('op', 'lib.save object Orb #metal #round'),
        ('sel', 'Orb'), ('op', 'lib.save object Orb2 #metal'),
        ('sel', 'Cube,Pillar'), ('op', 'lib.save object Gate #stone #metal'),
        ('op', 'lib.save tree Steps #nodes'),
        ('sel', 'Limb,Rig'), ('op', 'lib.save rig Puppet #character'),
        ('op', 'lib.save action Spin #move'),
        ('op', 'lib.save material Clay'),
        ('sel', 'Cube'), ('op', 'lib.save object GoldBox #shiny'),
        ('op', 'lib.tag Pillar #heavy'), ('op', 'lib.tag Orb2 -metal'), ('op', 'lib.tag Gate #stone -metal'),
        ('op', 'lib.save material Rock #textured'), ('op', 'material.save_asset Rock'),
        ('op', 'lib.save scene Yard #template'),
        ('op', 'lib.save object'), ('op', 'lib.save bogus'), ('op', 'lib.save material Nope'),
        ('op', 'lib.tag Nope #x'), ('op', 'lib.place Nope'),
        ('op', 'lib.save object Orb3 #a#b'),
        ('op', 'lib.remove Orb3'),
        ('op', 'tree.save_asset Steps'), ('op', 'material.save_asset Gold'), ('op', 'material.save_asset Clay'),
        ('op', 'lib.pack ~/BeeModel/metal.bee metal'), ('op', 'lib.pack ~/BeeModel/all.bee')]

BASE = {}


def base():
    """The scene, made by a script, then opened and saved once more (the
    file the library is saved from)."""
    if BASE:
        return BASE['p']
    h = home('base')
    b0 = os.path.join(T, 'base0.bee')
    from PIL import Image
    for nm, c in (('rock_albedo.png', (150, 120, 90)), ('rock_normal.png', (128, 128, 255)), ('rock_roughness.png', (200, 200, 200))):
        Image.new('RGB', (4, 4), c).save(os.path.join(T, nm))
    rc, _ = script(h, MAKE + f'op("material.import_textures", "{T}/rock_albedo.png Rock")\nop("file.save_as", "{b0}")')
    b1 = os.path.join(T, 'base.bee')
    rc2, _ = port(h, '--op', f'file.open {b0}', '--op', f'file.save_as {b1}')
    check(rc == 0 and rc2 == 0 and os.path.exists(b0) and os.path.exists(b1), f'the scene made by a script ({rc}), opened and saved again ({rc2})')
    BASE['p'] = b1
    return b1


KINDS = ('action', 'material', 'object', 'rig', 'scene', 'tree')
HEX = set('0123456789abcdef')


def well_formed(ix):
    """index.txt's lines that are not: id (16 hex), a known kind, a name, the
    blob (16 hex), dependencies (- or at most 8 ids), tags (- or words)."""
    bad = []
    for ln in (ix or '').splitlines():
        w = ln.split('\t')
        ok = len(w) == 6 and all(w) and len(w[0]) == 16 and set(w[0]) <= HEX and w[1] in KINDS \
            and len(w[3]) == 16 and set(w[3]) <= HEX
        if ok and w[4] != '-':
            d = w[4].split(',')
            ok = len(d) <= 8 and all(len(x) == 16 and set(x) <= HEX for x in d)
        if not ok:
            bad.append(ln[:80])
    return bad


def scene_line(ix):
    """index.txt's lines with the scene's id and blob left out."""
    out = []
    for ln in (ix or '').splitlines():
        w = ln.split('\t')
        if len(w) == 6 and w[1] == 'scene':
            w[0] = w[3] = '<scene>'
        out.append('\t'.join(w))
    return out


def tree_groups(tr):
    """A .beea of trees: [(tree, group node's tree number)] and the count."""
    if not tr or len(tr) < 16:
        return [], 0
    cnt = struct.unpack_from('<I', tr, 12)[0]
    out = []
    for k in range(cnt):
        r = 16 + k * 4096
        if r + 4096 > len(tr):
            break
        for i in range(min(struct.unpack_from('<I', tr, r + 128)[0], 48)):
            at = r + 160 + i * 72
            if struct.unpack_from('<I', tr, at)[0] == 26:
                out.append((k + 1, struct.unpack_from('<f', tr, at + 52)[0]))
    return out, cnt


def save_all(name, b):
    h = home(name)
    rc, lg = port(h, '--op', f'file.open {b}', *steps_port(SAVE))
    return h, rc, lg


def s_save():
    print('-- saving every kind: index.txt, blobs, .beea, packs --')
    b = base()
    hp, rc_p, lg = save_all('sp', b)
    check(rc_p == 0, f'it ran ({rc_p})')
    ip = index(hp)
    lp = scene_line(ip)
    kinds = sorted(set(l.split('\t')[1] for l in (ip or '').splitlines()))
    check(kinds == list(KINDS), f'every kind saved: {kinds}')
    bad = well_formed(ip)
    check(ip is not None and len(lp) >= 10 and not bad, f'index.txt: {len(lp)} lines, each well formed ({bad[:2]})')
    ids = [l.split('\t')[0] for l in (ip or '').splitlines()]
    check(len(set(ids)) == len(ids), 'index.txt: every id once')
    bp = blobs(hp)
    named = all(lbhash(v) == int(k[:16], 16) for k, v in bp.items())
    used = set(l.split('\t')[3] for l in (ip or '').splitlines())
    check(named and len(bp) == len(used) < len(lp),
          f'content-addressed: every blob named by the hash of its bytes; {len(bp)} blobs for {len(lp)} assets')
    # the scene blob: a .bee file, the scene's objects
    sc_p = [l.split('\t')[3] + '.bee' for l in (ip or '').splitlines() if l.split('\t')[1] == 'scene']
    if sc_p and sc_p[0] in bp:
        so = sorted(o['name'] for o in beefile.objects(bp[sc_p[0]]))
        sb = sorted(o['name'] for o in beefile.objects(b))
        check(so == sb, f'the scene blob: a .bee file with the scene\'s {len(so)} objects')
    else:
        check(False, 'the scene blob is there')
    # saved again from the same scene: the same library
    h2, rc2, _ = save_all('sp2', b)
    b2 = blobs(h2)
    sc2 = [l.split('\t')[3] + '.bee' for l in (index(h2) or '').splitlines() if l.split('\t')[1] == 'scene']
    s1 = {k: v for k, v in bp.items() if k not in sc_p}
    s2 = {k: v for k, v in b2.items() if k not in sc2}
    check(rc2 == 0 and scene_line(index(h2)) == lp and s1 == s2 and len(s1) >= 7,
          f'saved a second time: the same index.txt and {len(s1)} blobs (the scene\'s apart)')
    rk = rd(os.path.join(hp, 'BeeModel', 'assets', 'Rock.beea'))
    ni = [k for k in range(struct.unpack_from('<I', rk or bytes(200), 16 + 128)[0]) if struct.unpack_from('<I', rk, 16 + 160 + k * 72)[0] == 1]
    check(rk is not None and len(ni) >= 3 and all(struct.unpack_from('<f', rk, 16 + 160 + k * 72 + 52)[0] == 0 for k in ni),
          f'Rock.beea: its {len(ni)} image nodes saved empty (images stay with their scenes)')
    tg = [l.split('\t')[5] for l in (ip or '').splitlines() if l.split('\t')[2] == 'Gate']
    check(tg == ['stone'], f'tags: one added twice is there once, the last taken away takes its comma ({tg})')
    for f in ('Steps.beea', 'Gold.beea', 'Clay.beea', 'Rock.beea'):
        a = rd(os.path.join(hp, 'BeeModel', 'assets', f))
        check(a is not None and a[:4] == b'BEEA' and len(a) > 16, f'{f}: written ({len(a or b"")} bytes)')
    tr = rd(os.path.join(hp, 'BeeModel', 'assets', 'Steps.beea'))
    check(tr is not None and struct.unpack_from('<4I', tr) == (0x41454542, 1, 1, 3),
          'Steps.beea: its tree and the two groups it runs (nested)')
    gr, cnt = tree_groups(tr)
    check(len(gr) == 2 and all(1 <= g <= cnt and g != t for t, g in gr),
          f'Steps.beea: each group node names another tree of the file ({gr})')
    for f in ('metal.bee', 'all.bee'):
        c = rd(os.path.join(hp, 'BeeModel', f))
        ok = c is not None
        hs = []
        if ok:
            try:
                ch = beefile.chunks(c)
                hs = [x[:8] for t, x in ch if t == b'LIBB']
                ok = any(t == b'LIBM' for t, _ in ch) and len(hs) > 0 and len(set(hs)) == len(hs)
            except Exception:
                ok = False
        check(ok, f'lib.pack {f}: a manifest and {len(hs)} blobs, each once ({len(c or b"")} bytes)')
    for want in ('  library: saved object GoldBox', '  library: already there: material Clay',
                 '  library: already there: object GoldBox', '  tags: stone,column,heavy', '  library: removed Orb3',
                 '  library: no such material, tree or action: Nope', '  library: no asset named Nope',
                 '  lib.save object|rig|scene [name] [#tag ...] | material|tree|action <name> [#tag ...]',
                 '  pack written: 4 assets, 4 blobs', '  pack written: 13 assets, 11 blobs'):
        check(want in lg.splitlines(), f'it says "{want.strip()}"')
    return hp


# ---- placing from the library ---------------------------------------------------------------

PLACE = [('op', 'file.new'), ('op', 'lib.place Gate 10 0 0'), ('op', 'lib.place Puppet -10 0 0'),
         ('op', 'lib.place Orb 0 0 5'), ('sel', 'Cube'), ('op', 'lib.place Clay'), ('op', 'lib.place Steps'),
         ('sel', 'Pillar'), ('op', 'lib.place Spin')]


def scene_parts(p):
    """What placing is looked at by: objects, meshes, materials, modifiers,
    trees, bones and weights (by the object whose mesh has them). The
    default scene's Camera and Light are left out."""
    if not os.path.exists(p):
        return None
    ch = dict(beefile.chunks(p))
    obl = beefile.objects(p)
    objs = [(o['name'], [round(x, 5) for x in o['loc'] + o['rot'] + o['scl']], o['type'], o['flags'] & 1) for o in obl
            if not (o['type'] in (1, 2) and o['name'] in ('Camera', 'Light'))]
    ms = beefile.meshes(p)
    mesh = [(len(ms[o['mesh']][0]), len(ms[o['mesh']][1])) if o['type'] in (0, 4) and o['mesh'] < len(ms) else None for o in obl
            if not (o['type'] in (1, 2) and o['name'] in ('Camera', 'Light'))]
    by_mesh = {}
    for o in obl:
        by_mesh.setdefault(o['mesh'], []).append(o['name'])

    def recs(c, size_of):
        out, at = [], 0
        while c and at + 8 <= len(c):
            n = size_of(c, at)
            out.append((tuple(by_mesh.get(struct.unpack_from('<I', c, at)[0], [])), c[at + 4:at + n]))
            at += n
        return sorted(out)
    armt = recs(ch.get(b'ARMT'), lambda c, at: 16448)
    mwgt = recs(ch.get(b'MWGT'), lambda c, at: 8 + 20 * struct.unpack_from('<I', c, at + 4)[0])
    # each object's material by name (MATS: 128-byte records, the name first; OMAT: a number each, 0 none)
    mt = ch.get(b'MATS', b'\0\0\0\0')
    mnames = [mt[4 + k * 128:4 + k * 128 + 32].split(b'\0')[0].decode(errors='replace') for k in range(struct.unpack_from('<I', mt)[0])]
    om = ch.get(b'OMAT', b'\0\0\0\0')
    omat = {}
    for k, o in enumerate(obl):
        if 4 + k * 4 + 4 <= len(om):
            i = struct.unpack_from('<I', om, 4 + k * 4)[0]
            omat[o['name']] = mnames[i - 1] if 0 < i <= len(mnames) else None
    return dict(objs=objs, mesh=mesh, mats=mnames, omat=omat, mgrf=ch.get(b'MGRF'), ntre=ch.get(b'NTRE'),
                mods=ch.get(b'MODS'), armt=armt, mwgt=mwgt, by={o['name']: o for o in obl}, ms=ms)


def s_cross(hp):
    print('-- placing from the library, assets, packs --')
    b = base()
    sb = scene_parts(b)
    c = home('xp')
    shutil.copytree(lib_dir(hp), lib_dir(c))
    pp = os.path.join(T, 'xp.bee')
    if os.path.exists(pp):
        os.remove(pp)
    rc, lg = port(c, *steps_port(PLACE), '--op', f'file.save_as {pp}')
    p = scene_parts(pp)
    names = [x[0] for x in (p or {}).get('objs', [])]
    check(rc == 0 and p is not None and len(names) >= 6, f'placed and saved: {names}')
    check('  library: placed Gate' in lg and '  library: placed Spin' in lg, 'it says what it placed')
    if p is None:
        return
    # Gate (Cube and Pillar) at 10 0 0, the first there (Pillar's x then the Spin action's);
    # Puppet (Limb and Rig) at -10 0 0: one there, the other as far from it as in the scene
    gc = next((n for n in names if n.startswith('Cube.')), None)
    by, bb = p['by'], sb['by']
    near = lambda a, b: all(abs(a[k] - b[k]) < 1e-4 for k in range(3))
    check(gc is not None and near(by[gc]['loc'], (10, 0, 0)) and 'Pillar' in by
          and near(by['Pillar']['loc'][1:] + (0,), [bb['Pillar']['loc'][k] - bb['Cube']['loc'][k] for k in (1, 2)] + [0]),
          f'Gate at 10 0 0: {gc} there {by[gc]["loc"] if gc else None}, Pillar beside it as in the scene')
    if 'Limb' in by and 'Rig' in by:
        off_s = [bb['Limb']['loc'][k] - bb['Rig']['loc'][k] for k in range(3)]
        off_p = [by['Limb']['loc'][k] - by['Rig']['loc'][k] for k in range(3)]
        check(near(off_s, off_p) and (near(by['Rig']['loc'], (-10, 0, 0)) or near(by['Limb']['loc'], (-10, 0, 0))),
              f'Puppet at -10 0 0: Limb and Rig as far apart as in the scene ({[round(x, 3) for x in off_p]})')
    else:
        check(False, f'Puppet placed: Limb and Rig ({names})')
    check(gc is not None and p['omat'].get(gc) == sb['omat']['Cube'] and p['omat'].get('Pillar') == sb['omat']['Pillar']
          and p['omat'].get('Orb') == sb['omat']['Orb'] and None not in (sb['omat']['Cube'], sb['omat']['Pillar'], sb['omat']['Orb']),
          f'their materials came along: {gc} {p["omat"].get(gc)}, Pillar {p["omat"].get("Pillar")}, Orb {p["omat"].get("Orb")}, as in the scene')
    check(p['omat'].get('Cube') == 'Clay', f'lib.place Clay: on the selected Cube ({p["omat"].get("Cube")})')
    # Orb: evaluated through its subsurf
    if 'Orb' in by and by['Orb']['mesh'] < len(p['ms']):
        nb, np_ = len(sb['ms'][bb['Orb']['mesh']][0]), len(p['ms'][by['Orb']['mesh']][0])
        check(np_ > nb, f'Orb placed evaluated: {np_} vertices (its base mesh {nb})')
    else:
        check(False, 'Orb placed')
    # the rig bound again: the bones and weights as in the scene
    check(len(p['armt']) == len(sb['armt']) >= 1 and [x[1] for x in p['armt']] == [x[1] for x in sb['armt']]
          and [x[1] for x in p['mwgt']] == [x[1] for x in sb['mwgt']] and len(p['mwgt']) >= 1,
          f'Puppet: the rig bound again, {len(p["armt"])} armature(s), weights as in the scene')
    # asset.load of the .beea files
    c = home('ap')
    shutil.copytree(os.path.join(hp, 'BeeModel', 'assets'), os.path.join(c, 'BeeModel', 'assets'))
    pp = os.path.join(T, 'ap.bee')
    st = [('op', 'file.new'), ('op', 'asset.load Steps'), ('op', 'asset.load Steps'), ('op', 'asset.load Gold'),
          ('op', 'asset.load Clay'), ('op', 'asset.load Gold'), ('op', 'asset.load Nope'), ('op', 'asset.list')]
    rc, lg = port(c, *steps_port(st), '--op', f'file.save_as {pp}')
    p = scene_parts(pp)
    nt = struct.unpack_from('<I', (p or {}).get('ntre') or b'\0\0\0\0')[0]
    check(rc == 0 and nt == 6 and '  asset added: Steps.001' in lg and '  no such asset (or not one): Nope' in lg
          and '  asset: Clay' in lg, f'two Steps loaded: {nt} trees (with their groups, renumbered); the console says so')
    check(p is not None and 'Gold' in p['mats'] and 'Clay' in p['mats'], f'asset.load: the materials there ({(p or {}).get("mats")})')
    # lib.import of the packs into an empty library, twice
    c = home('ip')
    for f in ('metal.bee', 'all.bee'):
        shutil.copy(os.path.join(hp, 'BeeModel', f), os.path.join(c, 'BeeModel', f))
    st = [('op', 'lib.import ~/BeeModel/metal.bee'), ('op', 'lib.import ~/BeeModel/all.bee'), ('op', 'lib.import ~/BeeModel/all.bee'),
          ('op', 'lib.import ~/BeeModel/nothere.bee')]
    rc, lg = port(c, *steps_port(st))
    check(rc == 0 and sorted((index(c) or '').splitlines()) == sorted(index(hp).splitlines()) and blobs(c) == blobs(hp),
          f'lib.import of the packs: the library they came from, index.txt and {len(blobs(c))} blobs')
    check('  pack imported: 4 assets, 4 new, 4 blobs' in lg and '  pack imported: 13 assets, 9 new, 7 blobs' in lg
          and '  pack imported: 13 assets, 0 new, 0 blobs' in lg
          and '  not an asset pack: ' + os.path.join(c, 'BeeModel', 'nothere.bee') in lg,
          'the console on importing the packs')


# ---- damaged input ----------------------------------------------------------------------------

def s_damaged(hp):
    print('-- damaged index.txt, blobs, .beea files, packs --')
    good = index(hp).splitlines()
    rnd = random.Random(7)
    lines = good[:3] + [
        'zz00000000000001\tobject\tBad\t0000000000000001\t-\t-',
        '0000000000000002\tthing\tBad\t0000000000000001\t-\t-',
        '0000000000000003\tobject\tNoBlob\tnothex\t-\t-',
        '0000000000000004\tobject\tNoTab',
        '0000000000000005\tmaterial\t' + 'L' * 80 + '\t0000000000000001\t-\t' + 't' * 120,
        '0000000000000006\tobject\tDeps\t0000000000000001\t' + ','.join('%016x' % k for k in range(1, 12)) + '\tx,y',
        '0000000000000007\tobject\tHalfDeps\t0000000000000001\t00000000000000\tq',
        '0000000000000008\tobject\tNoTags\t0000000000000001\t-',
        good[0], '', '\t\t\t', 'X' * 700, '0000000000000009\tscene\tS\t0000000000000001\t-\t-\textra\tfields',
        '000000000000000A\tRIG\tUpper\t0000000000000001\t-\t-', '000000000000000b\trig\tlower\t0000000000000001\t-\t-']
    lines += [''.join(chr(rnd.randrange(1, 128)) for _ in range(rnd.randrange(0, 90))) for _ in range(30)]
    text = '\n'.join(lines)
    first = good[0].split('\t')[2]
    for case, data in (('lines', text), ('cut', text[:len(text) // 2]), ('no newline at the end', text.rstrip('\n'))):
        c = home('dp')
        os.makedirs(lib_dir(c))
        open(os.path.join(lib_dir(c), 'index.txt'), 'w', newline='').write(data)
        st = [('op', f'lib.tag {first} #seen')]
        r2, lg = port(c, *steps_port(st), '--op', 'lib.list')
        ix = index(c)
        bad = well_formed(ix)
        check(r2 == 0 and ix is not None and len(ix.splitlines()) >= 3 and not bad,
              f'damaged index.txt ({case}): read and written back well formed ({len((ix or "").splitlines())} lines; {bad[:2]})')
        r3, _ = port(c, *steps_port(st), '--op', 'lib.list')
        check(r3 == 0 and index(c) == ix, f'damaged index.txt ({case}): read again, the same file')
    # damaged blobs: an object asset's blob cut or scribbled over, then placed
    ix = [l.split('\t') for l in good]
    gate = [w for w in ix if w[2] == 'Gate'][0]
    blob = rd(os.path.join(lib_dir(hp), 'blobs', gate[3] + '.bee'))
    rnd = random.Random(11)
    m0 = 16 + 8 + 12  # (the first MESH's first vertex)
    oa = blob.index(b'OBJA') + 8
    cases = [('intact', blob), ('a vertex moved', blob[:m0] + struct.pack('<f', 7.5) + blob[m0 + 4:]),
             ('the second object\'s mesh past the meshes', blob[:oa + 128 + 80] + struct.pack('<I', 99) + blob[oa + 128 + 84:]),
             ('a material named that is not there', blob[:oa + 84] + b'Nowhere\0' + blob[oa + 92:]),
             ('empty', b''), ('15 bytes', blob[:15]), ('header only', blob[:16]), ('cut in a mesh', blob[:100]),
             ('cut in OBJA', blob[:-50]), ('magic wrong', b'XEEL' + blob[4:]), ('a mesh count huge', blob[:24] + b'\xff\xff\xff\x7f' + blob[28:])]
    for k in range(6):
        b2 = bytearray(blob)
        for _ in range(8):
            b2[rnd.randrange(16, len(b2))] = rnd.randrange(256)
        cases.append((f'scribbled {k}', bytes(b2)))
    for name, data in cases:
        c = home('bp')
        shutil.copytree(lib_dir(hp), lib_dir(c))
        open(os.path.join(lib_dir(c), 'blobs', gate[3] + '.bee'), 'wb').write(data)
        pp = os.path.join(T, 'bp.bee')
        if os.path.exists(pp):
            os.remove(pp)
        st = [('op', 'file.new'), ('op', 'lib.place Gate 1 2 3')]
        r2, _ = port(c, *steps_port(st), '--op', f'file.save_as {pp}')
        try:
            p = scene_parts(pp)
        except Exception as e:
            p = None
            print('     ', e)
        n = len((p or {}).get('objs', []))
        ok = r2 == 0 and p is not None and (n == 3 if name == 'intact' else n >= 1)
        check(ok, f'a damaged blob ({name}): no crash, the scene saved reads back ({n} objects)')
    # damaged .beea files
    tree = rd(os.path.join(hp, 'BeeModel', 'assets', 'Steps.beea'))
    mat = rd(os.path.join(hp, 'BeeModel', 'assets', 'Gold.beea'))
    v1 = struct.pack('<4I', 0x41454542, 1, 2, 1) + mat[16:16 + 1024]
    cases = [('short', tree[:10]), ('magic', b'XEEA' + tree[4:]), ('count 0', tree[:12] + b'\0\0\0\0' + tree[16:]),
             ('count 17', tree[:12] + struct.pack('<I', 17) + tree[16:]), ('a record short', tree[:-1]),
             ('kind 3', tree[:8] + struct.pack('<I', 3) + tree[12:]), ('version 2 trees', tree[:4] + struct.pack('<I', 2) + tree[8:]),
             ('a node count past 48', tree[:16 + 128] + struct.pack('<I', 99) + tree[16 + 132:]),
             ('a group past the file', tree[:16 + 160 + 2 * 72 + 52] + struct.pack('<f', 40) + tree[16 + 160 + 2 * 72 + 56:]),
             ('material short', mat[:16 + 40]), ('material version 3', mat[:4] + struct.pack('<I', 3) + mat[8:]),
             ('material v1 (1 KiB)', v1), ('material v1 short', v1[:500]),
             ('material graph nonsense', mat[:16 + 128] + struct.pack('<I', 60) + mat[16 + 132:])]
    for name, data in cases:
        c = home('ep')
        os.makedirs(os.path.join(c, 'BeeModel', 'assets'))
        open(os.path.join(c, 'BeeModel', 'assets', 'X.beea'), 'wb').write(data)
        pp = os.path.join(T, 'ep.bee')
        if os.path.exists(pp):
            os.remove(pp)
        st = [('op', 'file.new'), ('op', 'asset.load X')]
        r2, _ = port(c, *steps_port(st), '--op', f'file.save_as {pp}')
        try:
            p = scene_parts(pp)
        except Exception as e:
            p = None
            print('     ', e)
        check(r2 == 0 and p is not None, f'a damaged .beea ({name}): no crash, the scene saved reads back')
    # damaged packs
    pk = rd(os.path.join(hp, 'BeeModel', 'all.bee'))
    lb = pk.index(b'LIBB')
    cases = [('cut', pk[:len(pk) // 2]), ('a blob\'s hash wrong', pk[:lb + 8] + bytes([pk[lb + 8] ^ 1]) + pk[lb + 9:]),
             ('not BEEM', b'XEEM' + pk[4:]), ('a chunk size past the end', pk[:12] + b'\xff\xff\xff\x7f' + pk[16:])]
    for name, data in cases:
        c = home('kp')
        open(os.path.join(c, 'BeeModel', 'p.bee'), 'wb').write(data)
        st = [('op', 'lib.import ~/BeeModel/p.bee')]
        r2, _ = port(c, *steps_port(st))
        bc = blobs(c)
        named = all(lbhash(v) == int(k[:16], 16) for k, v in bc.items())
        bad = well_formed(index(c))
        check(r2 == 0 and named and not bad, f'a damaged pack ({name}): no crash, {len(bc)} blobs each under its own hash, index.txt well formed')
    # a group node naming no tree: saved as no group
    c = home('gp')
    r2, lg = port(c, '--op', 'tree.new A', '--op', 'tree.node A output', '--op', 'tree.node A group', '--op', 'tree.save_asset A')
    ga = rd(os.path.join(c, 'BeeModel', 'assets', 'A.beea'))
    check(r2 == 0 and ga is not None and len(ga) == 16 + 4096,
          f'a group node with no tree: the tree saved alone, the group none ({len(ga or b"")} bytes)')


# ---- undo ------------------------------------------------------------------------------------

def s_undo(hp):
    print('-- placing is one undo step --')
    h = home('up')
    shutil.copytree(lib_dir(hp), lib_dir(h))
    b = base()
    pa, pb, pc = (os.path.join(T, f'u{k}.bee') for k in 'abc')
    shots = [os.path.join(T, f'u{k}.ppm') for k in 'xy']
    port(h, '--op', f'file.open {b}', '--op', 'lib.place Gate 10 0 0', '--op', f'file.save_as {pa}',
         '--op', 'edit.undo', '--op', f'file.save_as {pb}', '--op', 'edit.redo', '--op', f'file.save_as {pc}')
    a, bb, c = scene_parts(pa), scene_parts(pb), scene_parts(pc)
    o = scene_parts(b)
    check(a is not None and bb is not None and c is not None and len(a['objs']) == len(o['objs']) + 2 and bb['objs'] == o['objs']
          and c['objs'] == a['objs'], f'lib.place Gate: {len(o["objs"])} -> {len((a or {}).get("objs", []))} objects; undo: as before; redo: placed again')
    # the view after undo shows the scene as before (a frame drawn after the place)
    vp = (212, 82, 1024, 630)
    rc, _ = port(h, '--op', f'file.open {b}', '--op', 'lib.place Gate 0 0 0')
    shutil.copy(os.path.join(h, 'u.ppm'), os.path.join(T, 'uz.ppm'))
    rc, _ = port(h, '--op', f'file.open {b}', '--op', 'lib.place Gate 0 0 0', '--op', 'edit.undo')
    shutil.copy(os.path.join(h, 'u.ppm'), shots[0])
    port(h, '--op', f'file.open {b}')
    shutil.copy(os.path.join(h, 'u.ppm'), shots[1])
    placed = area_diff(os.path.join(T, 'uz.ppm'), shots[1], vp)
    after = area_diff(shots[0], shots[1], vp)
    check(placed > 500 and after == 0, f'the viewport: {placed} pixels changed by the place, {after} apart from before it after the undo')


# ---- the window -------------------------------------------------------------------------------

def area_diff(a, b, box, skip=None):
    from PIL import Image, ImageChops
    d = ImageChops.difference(Image.open(a).convert('RGB'), Image.open(b).convert('RGB')).load()
    n = 0
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2]):
            if skip and skip[0] <= x < skip[2] and skip[1] <= y < skip[3]:
                continue
            if max(d[x, y]) > 30:
                n += 1
    return n


# the Asset Browser maximized: its header widgets and body
BOX = (130, 56, 1180, 780)


def browser(h, png, *extra):
    from PIL import Image
    rc, _ = port(h, '--op', 'area.type_asset_browser', '--op', 'area.maximize', *extra, '--move', '600,500')
    ok = rc == 0 and os.path.exists(os.path.join(h, 'u.ppm'))
    if ok:
        Image.open(os.path.join(h, 'u.ppm')).save(f'{T}/{png}')
    return ok


def s_window(hp):
    print('-- the Asset Browser --')
    ph = home('wp')
    shutil.copytree(lib_dir(hp), lib_dir(ph))
    th = os.path.join(T, 'th', 'BeeModel', 'library', 'thumbs')
    if os.path.isdir(th):
        shutil.copytree(th, os.path.join(lib_dir(ph), 'thumbs'), dirs_exist_ok=True)
    cases = [('tiles, thumbnails', 'p_plain.png', []),
             ('a tile selected: its kind, tags, uses, users', 'p_sel.png', ['--click', '80,120']),
             ('a search ("stone")', 'p_search.png', ['--op', 'lib.search stone']),
             ('"metal box", selected', 'p_search2.png', ['--op', 'lib.search metal box', '--click', '80,120']),
             ('nothing found', 'p_none.png', ['--op', 'lib.search nothing-like-it'])]
    drawn = {}
    for label, png, extra in cases:
        drawn[png] = browser(ph, png, *extra)
        check(drawn[png], f'the browser ({label}): drawn')
    if all(drawn.values()):
        for png, what in (('p_sel.png', 'a tile selected'), ('p_search.png', 'a search'), ('p_none.png', 'nothing found')):
            n = area_diff(f'{T}/p_plain.png', f'{T}/{png}', BOX)
            check(n > 0, f'{what}: the area changes ({n} pixels)')
    # more assets than fit: 150 of them; the empty library
    mp, ep = home('mp'), home('emp')
    gold = [l for l in index(hp).splitlines() if l.split('\t')[2] == 'Gold'][0].split('\t')
    lines = ['%016x\tmaterial\tM%03d\t%s\t-\tmany' % (0x1000 + k, k, gold[3]) for k in range(150)]
    os.makedirs(os.path.join(lib_dir(mp), 'blobs'))
    open(os.path.join(lib_dir(mp), 'index.txt'), 'w').write('\n'.join(lines) + '\n')
    m = browser(mp, 'p_many.png')
    e = browser(ep, 'p_empty.png')
    n = area_diff(f'{T}/p_many.png', f'{T}/p_empty.png', BOX) if m and e else 0
    check(m and e and n > 0, f'150 assets and the empty library: both drawn, {n} pixels apart')
    # a double-click places at the 3D cursor; a drag into the viewport lands on the
    # surface under the pointer; the tile menu
    dp = home('dd')
    shutil.copytree(lib_dir(hp), lib_dir(dp))
    pa = os.path.join(T, 'dbl.bee')
    pu = os.path.join(T, 'dblu.bee')
    rc, lg = port(dp, '--op', 'area.type_asset_browser', '--op', 'area.maximize', '--op', 'lib.search box',
                  '--dbl', '60,150', '--op', f'file.save_as {pa}', '--op', 'edit.undo', '--op', f'file.save_as {pu}')
    names = [x['name'] for x in beefile.objects(pa)] if os.path.exists(pa) else []
    un = [x['name'] for x in beefile.objects(pu)] if os.path.exists(pu) else []
    check(rc == 0 and 'Cube.001' in names and '  library: placed GoldBox' in lg,
          f'a double-click on a tile places it at the 3D cursor ({names})')
    check('Undo: Place Asset' in lg and 'Cube.001' not in un and un, f'one undo step, "Place Asset": undone ({un})')
    pd = os.path.join(T, 'drag.bee')
    # the default layout: the Asset Browser where the console is, a tile dragged up onto the cube
    rc, lg = port(dp, '--move', '700,690', '--op', 'area.type_asset_browser', '--op', 'lib.search box', '--dump-ui', f'{T}/dd_ui.txt')
    tile = None
    for ln in open(f'{T}/dd_ui.txt', errors='replace'):
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 4 and p[0] == 'tile' and p[1] == 'GoldBox':
            x, y, w, hh = map(int, p[2].split())
            tile = (x + w // 2, y + hh // 2)
    DROP = (615, 300)
    if tile:
        rc, lg = port(dp, '--move', '700,690', '--op', 'area.type_asset_browser', '--op', 'lib.search box',
                      '--drag', f'{tile[0]},{tile[1]},{DROP[0]},{DROP[1]}', '--op', f'file.save_as {pd}')
    new = [x for x in (beefile.objects(pd) if os.path.exists(pd) else []) if x['name'] == 'Cube.001']
    at = [round(c, 3) for c in new[0]['loc']] if new else None
    on_top = lambda p: p is not None and abs(p[1] - 2.0) < 0.05 and abs(p[0]) < 1 and abs(p[2]) < 1
    check(tile is not None and rc == 0 and on_top(at) and '  library: placed GoldBox' in lg,
          f'a tile dragged into the viewport lands on the cube\'s top under the pointer: {at}')
    rc, lg = port(dp, '--op', 'area.type_asset_browser', '--op', 'area.maximize', '--rclick', '60,150',
                  '--click-label', 'Show Dependencies')
    dl = [l.strip() for l in lg.splitlines() if l.startswith(('  uses:', '  used by:'))]
    check(dl == ['uses: -', 'used by: GoldBox, Gate, Cube'], f'the tile menu: Show Dependencies of the tile right-clicked (Gold: {dl})')


# ---- thumbnails ------------------------------------------------------------------------------

def s_thumbs(hp):
    print('-- thumbnails: path-traced by child processes --')
    from PIL import Image, ImageStat
    h = home('th')
    shutil.copytree(lib_dir(hp), lib_dir(h))
    shutil.rmtree(os.path.join(lib_dir(h), 'thumbs'), True)
    t0 = time.time()
    rc, lg = port(h, '--op', 'lib.thumbnails')
    secs = time.time() - t0
    td = os.path.join(lib_dir(h), 'thumbs')
    got = sorted(os.listdir(td)) if os.path.isdir(td) else []
    said = [ln for ln in lg.splitlines() if ln.startswith('  thumbnails made: ')]
    n_said = int(said[-1].split()[-1]) if said else -1
    shapes, blank = [], 0
    for f in got:
        try:
            im = Image.open(os.path.join(td, f)).convert('RGB')
            shapes.append(im.size)
            if max(ImageStat.Stat(im).stddev) < 1:
                blank += 1
        except Exception:
            shapes.append(None)
    check(rc == 0 and len(got) >= 10 and n_said == len(got), f'{len(got)} thumbnails in {secs:.1f} s (it says {n_said})')
    check(got and all(s == (128, 128) for s in shapes) and blank == 0, f'each a 128 x 128 PNG, none blank ({blank} blank)')
    rc, lg = port(h, '--op', 'lib.thumbnails')
    again = sorted(os.listdir(td)) if os.path.isdir(td) else []
    check(rc == 0 and again == got and '  thumbnails made: 0' in lg, 'again: none missing, none made')


# ---- timing ----------------------------------------------------------------------------------

def s_time(hp):
    print('-- a library of 1000 assets (a release build, one CPU) --')
    gold = [l for l in index(hp).splitlines() if l.split('\t')[2] == 'Gold'][0].split('\t')
    lines = ['%016x\t%s\tA%04d\t%s\t-\t%s' % (0x5000 + k, ('material', 'object', 'tree')[k % 3], k, gold[3], 'big,red' if k % 7 else 'tiny')
             for k in range(1000)]
    h = home('tm')
    os.makedirs(os.path.join(lib_dir(h), 'blobs'))
    open(os.path.join(lib_dir(h), 'index.txt'), 'w').write('\n'.join(lines) + '\n')
    N = 200
    # its own clock (--bench-lib), and the browser's frame (--bench)
    best_p = None
    for _ in range(3):
        r = subprocess.run(['taskset', '-c', CPU, REL, '--shot', os.path.join(h, 'u.ppm'), '--bench-lib', str(N)],
                           capture_output=True, text=True, env=dict(os.environ, HOME=h))
        w = [ln.split() for ln in r.stderr.splitlines() if ln.startswith('bench-lib:')]
        if w:
            v = [float(w[0][1]), float(w[0][4]), float(w[0][7]), float(w[0][10])]
            best_p = v if best_p is None else [min(a, b) for a, b in zip(best_p, v)]
    r = subprocess.run(['taskset', '-c', CPU, REL, '--shot', os.path.join(h, 'u.ppm'), '--op', 'area.type_asset_browser',
                        '--op', 'area.maximize', '--bench', '100'], capture_output=True, text=True, env=dict(os.environ, HOME=h))
    fr = [ln for ln in r.stderr.splitlines() if ln.startswith('bench:')]
    print(f'     ms, its clock: read {best_p[1] if best_p else "?"}, search {best_p[2] if best_p else "?"}, list {best_p[3] if best_p else "?"}; '
          f'the browser maximized: {fr[0] if fr else "?"}')
    check(best_p is not None and best_p[0] == 1000, f'it reads the 1000 assets ({best_p and best_p[0]})')
    check(best_p is not None and all(x == x and 0 <= x < 1e9 for x in best_p[1:]), 'the times measured (finite)')
    check(bool(fr), 'the browser draws a library of 1000 assets')


# ---- fuzzing (the debug build) -----------------------------------------------

def s_fuzz(hp, runs=12):
    print('-- random damage: index lines, blobs, .beea files, packs; random operations --')
    rnd = random.Random(int(os.environ.get('LB_SEED', '5')))
    src = lib_dir(hp)
    names = [l.split('\t')[2] for l in index(hp).splitlines()]
    bad = []
    for k in range(runs * 3):
        h = home('fz')
        shutil.copytree(src, lib_dir(h))
        shutil.copytree(os.path.join(hp, 'BeeModel', 'assets'), os.path.join(h, 'BeeModel', 'assets'))
        shutil.copy(os.path.join(hp, 'BeeModel', 'all.bee'), os.path.join(h, 'BeeModel', 'p.bee'))
        for p in [os.path.join(lib_dir(h), 'index.txt'), os.path.join(h, 'BeeModel', 'p.bee')] + \
                [os.path.join(lib_dir(h), 'blobs', f) for f in os.listdir(os.path.join(lib_dir(h), 'blobs'))] + \
                [os.path.join(h, 'BeeModel', 'assets', f) for f in os.listdir(os.path.join(h, 'BeeModel', 'assets'))]:
            d = bytearray(open(p, 'rb').read())
            if rnd.random() < 0.3 and d:
                d = d[:rnd.randrange(len(d))]
            for _ in range(rnd.randrange(0, 12)):
                if d:
                    d[rnd.randrange(len(d))] = rnd.randrange(256)
            open(p, 'wb').write(bytes(d))
        ops = []
        for _ in range(12):
            nm = rnd.choice(names + ['Nope', '', 'x' * 300])
            ops += ['--op', rnd.choice([f'lib.place {nm} {rnd.uniform(-9, 9):.2f} 0 1', f'lib.tag {nm} #t{rnd.randrange(9)} -t{rnd.randrange(9)}',
                                         f'lib.remove {nm}', f'lib.search {nm[:3]}', 'lib.list', f'lib.deps {nm}', 'lib.import ~/BeeModel/p.bee',
                                         'asset.load Steps', 'asset.load Gold', 'asset.load Rock', f'lib.save object {nm} #f', 'lib.pack ~/BeeModel/q.bee',
                                         'edit.undo', 'edit.redo', f'lib.save tree Steps #{nm[:5]}'])]
        rc, _ = port(h, '--op', f'file.open {base()}', '--select', 'Cube', '--op', 'area.type_asset_browser', *ops, timeout=300)
        if rc != 0:
            bad.append((k, rc))
    check(not bad, f'{runs * 3} random runs on damaged libraries: no crash, no hang ({bad[:3]})')


# ---- the user's files --------------------------------------------------------------------------

def s_home():
    now = _real_state()
    gone = sorted(set(_REAL0) - set(now))
    new = sorted(set(now) - set(_REAL0))
    changed = sorted(k for k in set(now) & set(_REAL0) if now[k] != _REAL0[k])
    check(not gone and not new and not changed,
          f'the real ~/BeeModel and ~/.config/beemodel{{,-zig}} untouched ({len(now)} entries; '
          f'gone {gone[:3]}, new {new[:3]}, changed {changed[:3]})')


def main():
    print(f'  BeeModel {BIN}')
    try:
        for _ in range(RUNS):
            hp = None
            if not ONLY or any(x in ONLY for x in ('s_save', 's_cross', 's_damaged', 's_undo', 's_window', 's_thumbs', 's_time', 's_fuzz')):
                hp = s_save()
            if not ONLY or 's_cross' in ONLY:
                s_cross(hp)
            if not ONLY or 's_damaged' in ONLY:
                s_damaged(hp)
            if not ONLY or 's_undo' in ONLY:
                s_undo(hp)
            if not ONLY or 's_thumbs' in ONLY:
                s_thumbs(hp)
            if not ONLY or 's_window' in ONLY:
                s_window(hp)
            if not ONLY or 's_time' in ONLY:
                s_time(hp)
            if not ONLY or 's_fuzz' in ONLY:
                s_fuzz(hp)
    finally:
        s_home()
        if not os.environ.get('LB_KEEP'):
            shutil.rmtree(T, True)
    print(f'\nthe content library: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
