#!/usr/bin/env python3
"""The phase 9 layer 2 review's defects:

  * s_uids: persistent object uids (UIDS: each object's id and the next id),
    so a feature that names a deleted body or sketch never binds to another
    object: files a BeeScript script saves opened, saved and rebuilt from the
    console, the console's read by a script, a body or a sketch deleted and
    then objects added, undo after a delete (an id never handed out twice),
    damaged UIDS chunks, and random records naming deleted, future and unknown
    uids: a script and the console the same, CADD and UIDS byte for byte (no
    uid normalising), every mesh.
  * s_dup: object.duplicate: the copy named after its source (Cube.001,
    S0.001, Body.001, Cube.002 from Cube.001), the copies the selection, no
    parent, default flags and light settings, the material, folder,
    modifiers, sketch and UVs kept, a script and the console the same; the
    console's "  duplicated: N"; Shift+D and F3 "Duplicate" in the window:
    a copy 2.5 along +X, no grab.
  * s_step: a STEP solid that tessellates to nothing still makes its objects
    (an empty mesh, every instance), so the names after it do not shift;
    such objects drawn, picked, exported, modified, edited and undone.
  * s_form: the Brush Colour form's colour field laid out as BeeModel's forms
    are (since they moved to BeeZigUi): its caption in the column on the left,
    the field filling the rest of the row to the box's right edge.
  * s_esc: a STEP import in the window shows progress and stops on Esc
    between solids.

    python3 tests/review10.py BIN [runs=20] [seed]

BEE_CPU (default 14) pins BeeModel; RV_ONLY=s_uids,s_dup ... runs some
(s_uids, s_dup, s_dup_window, s_step, s_form, s_esc).
"""
import os, random, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '14')
ONLY = [x for x in os.environ.get('RV_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beerv10-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee_eval(code, timeout=900):
    """A BeeScript script (--run, from a file: --eval takes so much)."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code + '\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 'timeout'


def port(*a, timeout=900):
    if os.path.exists(f'{T}/log.txt'):
        os.remove(f'{T}/log.txt')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = None
    lg = open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''
    return rc, lg


def oline(x):
    """A step as BeeScript: @A[,B] selects, 'op arg' runs an operator, '!pad
    BODY SKETCH VALUE MODE' pads (the console: the sketch selected, cad.pad)."""
    if x.startswith('!pad '):
        _, bd, sk, v, mo = x.split(' ')
        return f'_ = pad("{bd}", "{sk}", "{v}", "{mo}")'
    if x.startswith('@'):
        return 'select(' + ', '.join(f'"{n}"' for n in x[1:].split(',')) + ')'
    if x.startswith('param.set '):
        _, n, v = x.split(' ')
        return f'param("{n}", "{v}")'
    a = x.split(' ', 1)
    return f'op("{a[0]}"' + (f', "{a[1]}")' if len(a) > 1 else ')')


def pargs(steps):
    a = []
    for x in steps:
        if x.startswith('!pad '):
            _, bd, sk, v, mo = x.split(' ')
            a += ['--select', sk, '--op', f'cad.pad {bd} {v} {mo}']
        else:
            a += ['--select', x[1:]] if x.startswith('@') else ['--op', x]
    return a


def script_and_console(name, steps, pre=None):
    """The steps run as a script and as console operators (headless), each
    saving: (the script's file, the console's file, the console's log)."""
    fo, fp = f'{T}/{name}_o.bee', f'{T}/{name}_p.bee'
    for f in (fo, fp):
        if os.path.exists(f):
            os.remove(f)
    bee_eval('\n'.join(([f'op("file.open", "{pre}")'] if pre else []) + [oline(x) for x in steps] + [f'op("file.save_as", "{fo}")']))
    _, lg = port(*(['--op', f'file.open {pre}'] if pre else []), *pargs(steps), '--op', f'file.save_as {fp}')
    return fo, fp, lg


def uids(f):
    u = beefile.chunk(f, b'UIDS')
    n = struct.unpack_from('<I', u)[0]
    return list(struct.unpack_from(f'<{n}I', u, 4)), struct.unpack_from('<I', u, 4 + 4 * n)[0]


def frefs(f):
    """CADD's records: (body, sketch, status)."""
    c = beefile.chunk(f, b'CADD')
    np_ = struct.unpack_from('<I', c, 8)[0]
    o = 12 + np_ * 128
    nf = struct.unpack_from('<I', c, o)[0]
    return [struct.unpack_from('<3I', c, o + 8 + k * 128)[0:2] + (struct.unpack_from('<I', c, o + 4 + k * 128 + 24)[0],) for k in range(nf)]


def objmeshes(f):
    ms = [c for t, c in beefile.chunks(f) if t == b'MESH']
    return {o['name']: (ms[o['mesh']] if 0 <= o['mesh'] < len(ms) and o['type'] in (0, 3, 4) else None) for o in beefile.objects(f)}


def same_strict(a, b, what):
    """Meshes by object, CADD, UIDS and PRNT byte for byte."""
    if not (os.path.exists(a) and os.path.exists(b)):
        return False, f'{what}: a file is missing ({os.path.exists(a)}, {os.path.exists(b)})'
    why = []
    ma, mb = objmeshes(a), objmeshes(b)
    bad = [k for k in sorted(set(ma) | set(mb)) if ma.get(k) != mb.get(k)]
    if bad:
        why.append('meshes of ' + ', '.join(f'{k} ({len(ma.get(k) or b"")}/{len(mb.get(k) or b"")} bytes)' for k in bad))
    for t in (b'CADD', b'UIDS', b'PRNT'):
        if beefile.chunk(a, t) != beefile.chunk(b, t):
            why.append(t.decode() + (f' (refs {frefs(a)} / {frefs(b)})' if t == b'CADD' else f' ({uids(a)} / {uids(b)})' if t == b'UIDS' else ''))
    return not why, f'{what}: ' + ('; '.join(why) if why else 'the same')


def judge(a, b, what, new):
    """As same_strict, unless a feature record names an id at or past the
    first a `new` object of `a` got (a damaged or hand-made file): then the
    new objects of `b` must get ids past every id and reference, nothing is
    built on them, and the rest is as `a`."""
    if not (os.path.exists(a) and os.path.exists(b)):
        return False, f'{what}: a file is missing ({os.path.exists(a)}, {os.path.exists(b)})'
    oa = beefile.objects(a)
    ua, ub = uids(a), uids(b)
    refs = {x for r in frefs(a) for x in r[:2] if x}
    na = {o['name']: u for o, u in zip(oa, ua[0])}
    nb = {o['name']: u for o, u in zip(beefile.objects(b), ub[0])}
    first = min(na[n] for n in new if n in na)
    if not any(r >= first for r in refs):
        return same_strict(a, b, what)
    ma, mb = objmeshes(a), objmeshes(b)
    why = []
    if any(nb.get(n) in refs or nb.get(n, 0) <= max(refs | set(ub[0]) - {nb.get(m) for m in new}) for n in new):
        why.append(f'the new objects {[(n, nb.get(n)) for n in new]} take a named id (references {sorted(refs)})')
    if any(mb.get(n) != mb.get('Cube') for n in new):
        why.append('a new object was built on')
    bad = [k for k in ma if k not in new and ma.get(k) != mb.get(k)]
    if bad:
        why.append(f'meshes of {bad}')
    return not why, f'{what}: ' + ('; '.join(why) if why else f'the new objects {[(n, nb.get(n)) for n in new]} are past the referenced ids {sorted(refs)}')


def wrap(binary):
    p = f'{T}/run_{abs(hash(binary)) % 100000}.sh'
    open(p, 'w').write(f'#!/bin/sh\nexec taskset -c {CPU} {binary} "$@"\n')
    os.chmod(p, 0o755)
    return p


KEYS = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
KEYS.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12, '=': 13})
KEYS.update({str(i): i + 1 for i in range(1, 10)})


class Fw:
    """tests/wl_fake.py's compositor with the few helpers the cases use."""
    def __init__(self, binary):
        from wl_fake import Fake
        self.w = Fake(binary, size=(1280, 800))
        self.proc = self.w.proc
        self.w.until(lambda: self.w.frames > 0 and self.w.keyboard is not None and self.w.pointer is not None, 10)

    def pump(self, t=0.05):
        self.w.pump(t)

    def move(self, x, y):
        self.w.motion(x, y)

    def click(self, x, y):
        self.w.click(x, y)

    def mods(self, m):
        self.w.mods(m)

    def key(self, code):
        self.w.key(code)

    def type(self, text):
        for c in text:
            if c == '_':
                self.w.key(12, 1)
            elif c == ':':
                self.w.key(39, 1)
            elif c.isupper():
                self.w.key(KEYS[c.lower()], 1)
            else:
                self.w.key(KEYS[c])


class Win:
    """BeeModel in the fake compositor (tests/wl_fake.py)."""
    def __init__(self, binary):
        self.f = Fw(wrap(binary))
        self.home = tempfile.mkdtemp(dir=T)
        self.f.pump(1.0)
        self.f.w.enter(600, 350)
        self.f.move(600, 350)
        self.f.pump(0.3)
        self.n = 0

    def line(self, c):
        f = self.f
        f.key(28); f.pump(0.1); f.type(c); f.key(28); f.pump(0.5); f.key(1); f.pump(0.1)

    def save(self):
        p = f'{self.home}/s{self.n}.bee'
        self.n += 1
        self.line(f'file.save {p}')
        t0 = time.time()
        while not os.path.exists(p) and time.time() - t0 < 60:
            self.f.pump(0.1)
        self.f.pump(0.3)
        return p

    def image(self):
        from PIL import Image
        w = self.f.w
        s_ = w.surfaces[w.main().surface]
        bf = w.buffers[s_.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s_['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def close(self):
        self.f.proc.kill()
        self.f.proc.wait()


# ---- persistent uids ----------------------------------------------------------------------------

def s_uids():
    print('-- persistent uids: dangling feature references never bind to another object, every direction --')
    base = f'{T}/ubase.bee'
    bee_eval('\n'.join(['s = sketch("S0", "XY", 0)', 'r = rect(s, 0, 0, 2, 1)', 't = sketch("S1", "XY", 0)', 'r2 = circle(t, 5, 5, 1)',
                         '_ = pad("Body", "S0", "1")', '_ = pad("Body2", "S1", "2")', f'op("file.save_as", "{base}")']))
    check(os.path.exists(base) and uids(base) == ([1, 2, 3, 4, 5, 6, 7], 8), f'the base: uids {uids(base) if os.path.exists(base) else None}')
    # 1. a script deletes Body: its file names uid 6, which no object has
    od = f'{T}/odel.bee'
    bee_eval('\n'.join([f'op("file.open", "{base}")', 'select("Body")', 'op("object.delete")', f'op("file.save_as", "{od}")']))
    check(uids(od) == ([1, 2, 3, 4, 5, 7], 8) and [r[0] for r in frefs(od)] == [6, 7], f'the script\'s file: uids {uids(od)}, bodies {[r[0] for r in frefs(od)]}')
    a, b, _ = script_and_console('resave', [], od)
    ok, why = same_strict(a, b, 'that file opened and saved by a script and the console')
    check(ok, why)
    a, b, _ = script_and_console('rebuilt', ['param.set q 1'], od)
    ok, why = same_strict(a, b, 'and rebuilt (Body2 keeps its circle: the rectangle\'s feature finds no body)')
    check(ok and frefs(b)[0][2] == 8, why + f' (statuses {[r[2] for r in frefs(b)]})')
    # the console's resave opened by a script and rebuilt: as the script's own
    po = f'{T}/resave_po.bee'
    bee_eval('\n'.join([f'op("file.open", "{T}/resave_p.bee")', 'param("q", "1")', f'op("file.save_as", "{po}")']))
    ok, why = same_strict(a, po, 'the console\'s file rebuilt by a script')
    check(ok, why)
    # 2. a body / a sketch deleted, then objects added
    for name, steps in (('delbody', ['@Body', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('delsketch', ['@S1', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('delboth', ['@Body', 'object.delete', '@S0', 'object.delete', 'create.cube', 'create.cube', '@Cube.002', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('delthenpad', ['@Body2', 'object.delete', '@S1', 'object.delete', 'create.cube', '@S0', 'param.set q 1']),
                        ('delparent', ['@Cube,Body2', 'object.parent_set', '@S0', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('padthendel', ['!pad Body3 S1 1 normal', '@Body3', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('movethendel', ['cad.feature_move 1 up', '@Body', 'object.delete', 'create.cube', 'param.set q 1']),
                        ('newscene', ['file.new', 'create.cube', 'create.cube'])):
        a, b, _ = script_and_console(name, steps, base)
        ok, why = same_strict(a, b, f'{" then ".join(s for s in steps if not s.startswith("param"))}: a script and the console')
        check(ok and os.path.exists(b) and uids(b)[1] > max(uids(b)[0]), why + (f' (uids {uids(b)})' if os.path.exists(b) else ''))
    # the console's file, read by a script, which adds and rebuilds: as on the script's own
    a = f'{T}/delbody_o2.bee'
    bee_eval('\n'.join([f'op("file.open", "{T}/delbody_o.bee")', 'op("create.cube")', 'param("q", "2")', f'op("file.save_as", "{a}")']))
    b = f'{T}/delbody_po2.bee'
    bee_eval('\n'.join([f'op("file.open", "{T}/delbody_p.bee")', 'op("create.cube")', 'param("q", "2")', f'op("file.save_as", "{b}")']))
    ok, why = same_strict(a, b, 'the console\'s file (a body deleted) opened by a script, a cube added, rebuilt: as the script\'s')
    check(ok and uids(b)[0][-1] == 9, why + f' (the new cube\'s uid {uids(b)[0][-1]})')
    # 3. undo after a delete: the uid comes back, the next id does not
    pa = ['--op', f'file.open {base}', '--select', 'Body', '--op', 'object.delete', '--op', 'edit.undo', '--op', 'create.cube',
          '--select', 'S1', '--op', 'object.delete', '--op', 'edit.undo', '--op', 'edit.redo', '--op', 'create.cube', '--op', f'file.save_as {T}/undo_p.bee']
    port(*pa)
    ok = os.path.exists(f'{T}/undo_p.bee')
    check(ok and uids(f'{T}/undo_p.bee') == ([1, 2, 3, 4, 6, 7, 8, 9], 10), 'delete, undo, add; delete, undo, redo, add: Body\'s uid back, S1\'s gone, no id handed out twice'
          + (f' (uids {uids(f"{T}/undo_p.bee")})' if ok else ''))
    # 4. damaged UIDS chunks: a script and the console keep the same
    chs = beefile.chunks(od)
    u = beefile.chunk(od, b'UIDS')
    n = struct.unpack_from('<I', u)[0]
    cases = [('a count that is not the objects\'', struct.pack('<I', n + 1) + u[4:]), ('no next id', u[:4 + 4 * n]),
             ('cut in the ids', u[:12]), ('empty', b''), ('duplicate ids', struct.pack(f'<{n + 2}I', n, 1, 1, 2, 3, 4, 7, 8)),
             ('ids past the next one (kept)', struct.pack(f'<{n + 2}I', n, 1, 2, 3, 4, 5, 70, 80)),
             ('a next id behind the ids', struct.pack(f'<{n + 2}I', n, 1, 2, 3, 4, 5, 9, 4))]
    for k, (what, body) in enumerate(cases):
        p = f'{T}/dmg{k}.bee'
        open(p, 'wb').write(b'BEEM' + struct.pack('<I', 1) + b''.join(t + struct.pack('<I', len(c)) + c for t, c in
                                                                          ((t, body if t == b'UIDS' else c) for t, c in chs)))
        a, b, _ = script_and_console(f'dmg{k}', ['create.cube', 'param.set q 1'], p)
        ok, why = judge(a, b, f'UIDS {what}: opened, a cube added, rebuilt', ['Cube.001'])
        check(ok, why)
    # 5. random records naming live, deleted, future and unknown uids, opened by a script and the console, objects added, rebuilt
    rng = random.Random(SEED)
    names = []
    for k in range(RUNS):
        # (even: what a file can name - live, deleted, none; odd: past its next id too)
        pool = [4, 5, 6, 7, 0] if k % 2 == 0 else [4, 5, 6, 7, 8, 9, 10, 99, 0]
        recs = b''
        nf = rng.randrange(1, 5)
        for _ in range(nf):
            t = rng.choice([1, 1, 2, 3])
            r = bytearray(struct.pack('<8I', t, rng.choice(pool), rng.choice(pool), 0, 0, 0, 99, rng.randrange(0, 2)))
            sl = bytearray(32)
            sl[0] = 1
            struct.pack_into('<d', sl, 8, rng.choice([0.5, 1.0, 1.5]))
            r += sl + bytes(64)
            recs += bytes(r)
        c = beefile.chunk(od, b'CADD')
        np_ = struct.unpack_from('<I', c, 8)[0]
        o2 = 12 + np_ * 128
        c2 = c[:o2] + struct.pack('<I', nf) + recs + c[o2 + 4 + struct.unpack_from('<I', c, o2)[0] * 128:]
        p = f'{T}/rnd{k}.bee'
        open(p, 'wb').write(b'BEEM' + struct.pack('<I', 1) + b''.join(t + struct.pack('<I', len(x)) + x for t, x in
                                                                          ((t, c2 if t == b'CADD' else x) for t, x in chs)))
        names.append(p)
    steps = ['create.cube', 'create.cube', 'param.set q 1']
    bee_eval('\n'.join(f'op("file.open", "{p}")\n' + '\n'.join(oline(x) for x in steps) + f'\nop("file.save_as", "{p}.o.bee")' for p in names))
    for lo in range(0, len(names), 8):
        args = []
        for p in names[lo:lo + 8]:
            args += ['--op', f'file.open {p}', *pargs(steps), '--op', f'file.save_as {p}.p.bee']
        port(*args)
    same = 0
    for p in names:
        ok, why = judge(p + '.o.bee', p + '.p.bee', os.path.basename(p), ['Cube.001', 'Cube.002'])
        if ok:
            same += 1
        else:
            print('      ' + why)
    check(same == len(names), f'{same} of {len(names)} files with random references (live, deleted, the next ids, unknown): a script and the console the same after adding objects and a rebuild')
    # the console's files from those: a script reads them as the console does (nothing binds there either)
    bee_eval('\n'.join(f'op("file.open", "{p}.p.bee")\nparam("q", "3")\nop("file.save_as", "{p}.po.bee")' for p in names))
    args = []
    for p in names:
        args += ['--op', f'file.open {p}.p.bee', '--op', 'param.set q 3', '--op', f'file.save_as {p}.pp.bee']
    port(*args)
    same = sum(1 for p in names if same_strict(p + '.po.bee', p + '.pp.bee', '')[0])
    check(same == len(names), f'{same} of {len(names)}: the console\'s files reopened and rebuilt by a script and the console the same')


# ---- object.duplicate ----------------------------------------------------------------------------

SKIP = {b'WSPC', b'PREF', b'THMB', b'VIEW', b'LCAM', b'ANIM', b'CURV', b'FLDS', b'LAND', b'MPIN', b'PSYS', b'SIMC', b'TEXT'}


LOOSE = [False]


def norm(f, t, c):
    """A chunk without what differs for reasons of its own: OBJS's mesh
    numbers, SKCH's block reference counts (a script is one undo step, the
    console's ops each one), MUVS's mesh numbers (as the objects that use them)."""
    if t == b'OBJS':
        d = bytearray(c)
        for k in range(struct.unpack_from('<I', d)[0]):
            d[4 + k * 84 + 80:4 + k * 84 + 84] = bytes(4)
            if LOOSE[0]:
                # (a child's world transform: kept local, written as parent x
                # local, decomposed - a few ulps off)
                v = [round(x, 5) + 0.0 for x in struct.unpack_from('<9f', d, 4 + k * 84 + 32)]
                struct.pack_into('<9f', d, 4 + k * 84 + 32, *v)
        return bytes(d)
    if t == b'SKCH':
        # (records: the object's index, then the block, SK_SZ bytes: refs first)
        d = bytearray(c)
        n = struct.unpack_from('<I', d)[0]
        step = (len(d) - 4) // n if n else 0
        for k in range(n):
            d[4 + k * step + 4:4 + k * step + 8] = bytes(4)
        return bytes(d)
    if t == b'MUVS':
        # records by the objects whose mesh they are
        users = {}
        for ob in beefile.objects(f):
            users.setdefault(ob['mesh'], []).append(ob['name'])
        out, o = [], 0
        while len(c) - o >= 12:
            ix, fl, nl = struct.unpack_from('<3I', c, o)
            size = (nl * 8 if fl & 1 else 0) + ((nl + 3) & ~3 if fl & 2 else 0)
            out.append((tuple(sorted(users.get(ix, []))), c[o + 4:o + 12 + size]))
            o += 12 + size
        return sorted(out)
    return c


def chunk_diff(a, b):
    ca, cb = {}, {}
    for f, dct in ((a, ca), (b, cb)):
        for t, c in beefile.chunks(f):
            if t in SKIP or t == b'MESH':
                continue
            dct.setdefault(t, []).append(norm(f, t, c))
    out = [t.decode() for t in sorted(set(ca) | set(cb)) if ca.get(t) != cb.get(t)]
    if objmeshes(a) != objmeshes(b):
        out.append('MESH')
    return out


def rows(f):
    return [(o['name'], tuple(round(x, 4) for x in o['loc']), o['flags']) for o in beefile.objects(f)]


def s_dup():
    print('-- object.duplicate: names, place, selection, what a copy carries; the console\'s line --')
    base = f'{T}/dbase.bee'
    bee_eval('\n'.join(['s = sketch("S0", "XY", 0)', 'r = rect(s, 0, 0, 2, 1)', '_ = pad("Body", "S0", "1")', f'op("file.save_as", "{base}")']))
    base2 = f'{T}/dbase2.bee'
    bee_eval('\n'.join([f'op("file.open", "{base}")', 'move("Body", 1, 0, 3)', 'rotate("Body", 0, 0, 30)', 'select("Cube", "Body")',
                         'op("object.parent_set")', 'select("Cube")', 'op("object.move_to_folder", "F1")', f'op("file.save_as", "{base2}")']))
    base3 = f'{T}/dbase3.bee'
    chs = beefile.chunks(base)
    ob = bytearray(beefile.chunk(base, b'OBJS'))
    for k, o in enumerate(beefile.objects(base)):
        if o['name'] == 'Body':
            struct.pack_into('<I', ob, 4 + k * 84 + 76, o['flags'] | 0x400 | 0x800 | 0x1000)   # locked, not rendered, folded
    open(base3, 'wb').write(b'BEEM' + struct.pack('<I', 1) + b''.join(t + struct.pack('<I', len(c)) + c for t, c in
                                                                       ((t, bytes(ob) if t == b'OBJS' else c) for t, c in chs)))
    cases = [
        ('the cube', ['@Cube', 'object.duplicate'], base, ['Cube.001']),
        ('a locked, not rendered one (the copy has neither)', ['@Body', 'object.duplicate'], base3, ['Body.001']),
        ('twice (Cube.001 gives Cube.002)', ['@Cube', 'object.duplicate', 'object.duplicate'], base, ['Cube.001', 'Cube.002']),
        ('a sketch', ['@S0', 'object.duplicate'], base, ['S0.001']),
        ('a feature\'s body, then a rebuild', ['@Body', 'object.duplicate', 'param.set q 1'], base, ['Body.001']),
        ('three at once (the last active)', ['@Cube,Body,Light', 'object.duplicate'], base, ['Light.001', 'Cube.001', 'Body.001']),
        ('a material, a modifier, a folder', ['@Cube', 'material.new Red', 'object.modifier_add_subsurf', 'object.move_to_folder F2', 'object.duplicate'], base, ['Cube.001']),
        ('UVs', ['@Cube', 'uv.smart_project', 'object.duplicate'], base, ['Cube.001']),
        ('a child of a moved, turned parent (no parent, where it was)', ['@Cube', 'object.duplicate'], base2, ['Cube.001']),
        ('a parent', ['@Body', 'object.duplicate'], base2, ['Body.001']),
        ('beside a hidden one', ['@Cube', 'object.hide', '@Body', 'object.duplicate'], base, ['Body.001']),
        ('in edit mode: refused', ['@Cube', 'mode.edit', 'object.duplicate', 'mode.object', '@Body', 'object.duplicate'], base, ['Body.001']),
    ]
    for what, steps, pre, new in cases:
        LOOSE[0] = pre == base2
        a, b, lg = script_and_console('dup', steps, pre)
        d = chunk_diff(a, b) if os.path.exists(a) and os.path.exists(b) else ['missing']
        got = [r[0] for r in rows(b)][-len(new):] if os.path.exists(b) else None
        check(not d and got == new and lg.count('  duplicated: ') == sum(1 for s in steps if s == 'object.duplicate') - ('mode.edit' in steps) and
              lg.count('  not available in edit mode yet (Tab returns to object mode)') == ('mode.edit' in steps),
              f'{what}: {"the same file" if not d else "differs in " + ",".join(d)}; the new {got}; "{[l for l in lg.splitlines() if "duplicated" in l]}"')
        if d and 'OBJS' in d:
            print('      script ', rows(a)[-3:], '\n      console', rows(b)[-3:])
    LOOSE[0] = False
    # the console's words
    _, lg = port('--op', f'file.open {base}', '--select', 'Cube', '--op', 'object.duplicate', '--select', 'Cube,Body', '--op', 'object.duplicate',
                 '--op', 'object.select_all', '--op', 'object.select_all', '--op', 'object.duplicate', '--op', f'file.save_as {T}/mcp_p.bee',
                 '--op', 'mode.edit', '--op', 'object.duplicate')
    got = [[ln for ln in g if ln.startswith('  ') or ln.startswith('!')] for g in answers(lg.splitlines())]
    pg = [got[k] for k in (1, 2, 5, 8)] if len(got) > 8 else got
    n = len(beefile.objects(f'{T}/mcp_p.bee')) if os.path.exists(f'{T}/mcp_p.bee') else 0
    want = [['  duplicated: 1'], ['  duplicated: 2'], [f'  duplicated: {n // 2}'], ['  not available in edit mode yet (Tab returns to object mode)']]
    check(pg == want and n == 16, f'the console: {pg} ({n} objects after)')


def skrefs(f):
    c = beefile.chunk(f, b'SKCH')
    n = struct.unpack_from('<I', c)[0]
    step = (len(c) - 4) // n if n else 0
    return [struct.unpack_from('<I', c, 4 + k * step + 4)[0] for k in range(n)]


def answers(lines):
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


def s_dup_window():
    print('-- Shift+D and F3 "Duplicate" in the window: a copy 2.5 along +X, no grab (the pointer moved and clicked after) --')
    w = Win(BIN)
    try:
        f = w.f
        f.move(600, 350); f.pump(0.2)
        f.mods(1); f.key(32); f.mods(0); f.pump(0.6)     # Shift+D (the cube is selected)
        f.move(700, 420); f.pump(0.4); f.move(760, 480); f.pump(0.4)
        f.click(760, 480); f.pump(0.5)
        a = w.save()
        w.line('object.select_all')                       # (the click selected nothing: now all of them)
        f.key(61); f.pump(0.4); w.f.type('object.duplicate'); f.pump(0.4); f.key(28); f.pump(0.8)   # F3 (by its id)
        f.move(500, 300); f.pump(0.4); f.click(500, 300); f.pump(0.5)
        b = w.save()
    finally:
        w.close()
    rb = rows(a) if os.path.exists(a) else []
    check(len(rb) == 4 and rb[-1][0] == 'Cube.001' and rb[-1][1] == (2.5, 1.0, 0.0), f'Shift+D: {rb[-2:]}')
    rb = rows(b) if os.path.exists(b) else []
    check(len(rb) == 8 and [r[1] for r in rb[4:]] == [(r[1][0] + 2.5,) + r[1][1:] for r in rb[:4]], f'F3 Duplicate (four selected): {len(rb)} objects, each copy 2.5 along +X ({[r[0] for r in rb][4:]})')


# ---- STEP: solids without triangles ----------------------------------------------------------------

SOLIDS = '''
s = sketch("SBox", "XY")
rect(s, 0, 0, 2, 1)
pad("Box", s, 0.5)
c = sketch("SCyl", "XZ")
circle(c, 10, 0, 1)
pad("Cyl", c, 2)
g = sketch("SRing", "XY")
rect(g, -2, -1, 4, 2)
circle(g, 0, 0, 0.5)
pad("Plate", g, 0.3)
'''


def empty_variants(txt):
    """The solids' file with Box (and Cyl) tessellating to nothing, Box placed
    three times: its shell empty; a face of Cyl without bounds, the rest gone."""
    ents = {int(m.group(1)): m.group(2) for m in re.finditer(r'#(\d+)=(.*?);\r?\n', txt)}
    def solid(name):
        for k, v in ents.items():
            if v.startswith(f"MANIFOLD_SOLID_BREP('{name}'"):
                return k, int(re.search(r'#(\d+)\)', v).group(1))
    bx, bsh = solid('Box')
    cx, csh = solid('Cyl')
    brep_rep = [k for k, v in ents.items() if v.startswith('ADVANCED_BREP_SHAPE_REPRESENTATION') and re.search(rf'#{bx}\b', v)][0]
    m = re.search(r"#(\d+)=\(REPRESENTATION_RELATIONSHIP\('',''," + rf"#{brep_rep},#(\d+)\) REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION\(#(\d+)\)", txt)
    assy_rep, idt = int(m.group(2)), int(m.group(3))
    first = re.search(rf"#{idt}=ITEM_DEFINED_TRANSFORMATION\('','',#(\d+),#(\d+)\)", txt)
    cdsr = re.search(rf"#(\d+)=CONTEXT_DEPENDENT_SHAPE_REPRESENTATION\(#{m.group(1)},#(\d+)\)", txt)
    extra = ''
    for k, (x, y) in enumerate(((5, 0), (0, 4))):
        b = 5000 + k * 10
        extra += (f"#{b}=CARTESIAN_POINT('',({x}.,{y}.,0.));\n#{b + 1}=DIRECTION('',(0.,0.,1.));\n#{b + 2}=DIRECTION('',(1.,0.,0.));\n"
                  f"#{b + 3}=AXIS2_PLACEMENT_3D('',#{b},#{b + 1},#{b + 2});\n#{b + 4}=ITEM_DEFINED_TRANSFORMATION('','',#{first.group(1)},#{b + 3});\n"
                  f"#{b + 5}=(REPRESENTATION_RELATIONSHIP('','',#{brep_rep},#{assy_rep}) REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#{b + 4}) SHAPE_REPRESENTATION_RELATIONSHIP());\n"
                  f"#{b + 6}=CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#{b + 5},#{cdsr.group(2)});\n")
    out = re.sub(rf"#{bsh}=CLOSED_SHELL\('',\(.*?\)\);", f"#{bsh}=CLOSED_SHELL('',());", txt)
    out = out.replace('ENDSEC;\nEND-ISO', extra + 'ENDSEC;\nEND-ISO')
    cfaces = re.search(rf"#{csh}=CLOSED_SHELL\('',\((#\d+)", out).group(1)
    out = re.sub(rf"#{csh}=CLOSED_SHELL\('',\(.*?\)\);", f"#{csh}=CLOSED_SHELL('',({cfaces}));", out)
    out = re.sub(rf"{cfaces}=ADVANCED_FACE\('',\(.*?\),", f"{cfaces}=ADVANCED_FACE('',(),", out)
    return out


def s_step():
    print('-- STEP: solids that tessellate to nothing still make their objects (an empty mesh); the names after them stay --')
    src = f'{T}/solids.step'
    bee_eval(f'op("cad.kernel", "on")\ndelete("Cube")\n' + SOLIDS + f'op("file.export_step", "{src}")\n')
    if not os.path.exists(src):
        check(False, 'the script wrote no fixture')
        return
    fx = f'{T}/empty.step'
    open(fx, 'w').write(empty_variants(open(src).read()))
    a, b, lg = script_and_console('emp', [f'file.import_step {fx}'])
    # (not the default scene's)
    ra = [(o['name'], tuple(round(x, 5) for x in o['loc']), o['color']) for o in beefile.objects(a)][3:] if os.path.exists(a) else None
    rb = [(o['name'], tuple(round(x, 5) for x in o['loc']), o['color']) for o in beefile.objects(b)][3:] if os.path.exists(b) else None
    ma, mb = ({k: v for k, v in objmeshes(f).items() if k not in ('Camera', 'Light', 'Cube')} for f in (a, b)) if ra and rb else ({}, {})
    empty = [k for k, v in mb.items() if v is not None and struct.unpack_from('<I', v)[0] == 0]
    check(ra == rb and ma == mb and sorted(empty) == ['Box', 'Box.001', 'Box.002', 'Cyl'],
          f'imported: {[r[0] for r in rb] if rb else None} (empty: {sorted(empty)}), by a script {[r[0] for r in ra] if ra else None}: places, colours, meshes {"the same" if ma == mb else "NOT the same"}')
    # every path an object goes through, on the empty ones (debug build: no panic, no leak report)
    ex = f'{T}/ex'
    os.makedirs(ex, exist_ok=True)
    steps = [f'file.import_step {fx}', 'object.select_all', 'object.select_all', 'view.frame_selected', 'view.shading_wireframe', 'view.shading_material', 'view.shading_rendered', 'view.shading_solid', 'view.show_normals', 'view.show_nonmanifold',
             f'file.export_obj {ex}/a.obj', f'file.export_stl {ex}/a.stl', f'file.export_3mf {ex}/a.3mf', f'file.export_gltf {ex}/a.gltf',
             f'file.export_step {ex}/a.step', '@Box', 'object.modifier_add_subsurf', 'object.modifier_add_array', 'object.modifier_add_solidify',
             'object.modifier_add_bevel', 'object.modifier_add_mirror', 'object.modifier_add_decimate', 'object.modifier_add_remesh',
             'object.modifier_apply', 'mode.edit', 'mesh.select_all', 'mesh.extrude', 'mesh.subdivide', 'mode.object', 'uv.smart_project',
             'mode.sculpt', 'mode.object', 'object.measure', 'object.duplicate', 'object.boolean_union', 'edit.undo', 'edit.undo', 'edit.redo',
             f'file.save_as {ex}/a.bee', f'file.open {ex}/a.bee', '@Box', 'object.delete', 'edit.undo']
    clicks = []
    for x, y in ((640, 400), (300, 300), (900, 500)):
        clicks += ['--click', f'{x},{y}']
    rc, lg = port(*pargs(steps), *clicks, '--op', f'render.image {ex}/r.png 64 48 2', timeout=1800)
    check(rc == 0 and 'panic' not in lg, f'{len(steps) + 4} steps on the empty objects (draw, pick, exports, modifiers, edit mode, sculpt, booleans, undo, files, a render): exit {rc}')


# ---- the form's colour field ----------------------------------------------------------------------

def s_form():
    print('-- F3 "Brush Colour": the colour field after its caption, to the right edge of the box --')
    port('--move', '600,350', '--key', 'f3', '--type', 'Brush Colour', '--key', 'enter', '--move', '100,700')
    rs = [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt', errors='replace')] if os.path.exists(f'{T}/u.txt') else []
    dlg = [r for r in rs if len(r) >= 3 and r[0] == 'dialog' and r[1] == 'Brush Colour']
    inside = lambda r: dlg and all(int(a) <= int(b) for a, b in zip(dlg[0][2].split()[:2], r[2].split()[:2])) and int(r[2].split()[0]) < sum(map(int, dlg[0][2].split()[::2]))
    fld = [r for r in rs if len(r) >= 3 and r[0] == 'colour' and inside(r)]
    if not (dlg and fld):
        check(False, f'the form opens with its colour field ({bool(dlg)}, {bool(fld)})')
        return
    dx, dy, dw, dh = map(int, dlg[0][2].split())
    fx, fy, fw, fh = map(int, fld[0][2].split())
    # (the forms' caption column is 126 units, plus the dialog's padding and a gap)
    check(24 < fx - dx <= 200 and dx + dw - (fx + fw) <= 24 and fw >= dw // 3,
          f'the field after its caption, to the right edge (dialog {dx}..{dx + dw}, field {fx}..{fx + fw})')


# ---- a STEP import stopped by Esc ----------------------------------------------------

def s_esc():
    print('-- a long STEP import in the window: progress, and Esc stops it between solids --')
    src = f'{T}/many.step'
    body = '\n'.join(f's{k} = sketch("S{k}", "XY")\nrect(s{k}, {5 * k}, 0, 4, 3)\ncircle(s{k}, {5 * k + 1}, 1, 0.4)\ncircle(s{k}, {5 * k + 3}, 2, 0.4)\n'
                     f'pad("P{k}", s{k}, 0.5)\nfillet("P{k}", 0.1, "vertical")' for k in range(30))  # (64 features at most)
    bee_eval(f'op("cad.kernel", "on")\ndelete("Cube")\n{body}\nop("file.export_step", "{src}")\n', timeout=1800)
    if not os.path.exists(src):
        check(False, 'the script wrote no fixture')
        return
    n_file = open(src).read().count('MANIFOLD_SOLID_BREP(')
    t0 = time.time()
    _, lg = port('--op', f'file.import_step {src}', '--op', f'file.save_as {T}/all.bee', timeout=1800)
    took = time.time() - t0
    n_all = len(beefile.objects(f'{T}/all.bee')) - 3 if os.path.exists(f'{T}/all.bee') else 0
    w = Win(BIN)
    try:
        f = w.f
        f.key(28); f.pump(0.1); w.f.type(f'file.import_step {src}'); f.key(28)
        f.pump(min(1.0, took / 4))
        mid = w.image()                                     # (the job's chip: "Importing STEP n%")
        f.key(1); f.pump(0.2)                               # Esc while it runs
        f.key(1); f.pump(0.2)
        p = None
        t1 = time.time()
        while time.time() - t1 < 600:
            p = w.save()
            if os.path.exists(p):
                break
        n_stop = len(beefile.objects(p)) - 3 if p and os.path.exists(p) else -1
    finally:
        w.close()
    if os.environ.get('RV_KEEP'):
        mid.save(f'{os.environ["RV_KEEP"]}/esc_mid.png')
    check(n_all == n_file and 0 <= n_stop < n_all, f'all {n_file} solids headless ({n_all}, {took:.1f} s); Esc in the window stopped it at {n_stop}')


SECTIONS = [s_uids, s_dup, s_dup_window, s_step, s_form, s_esc]

if __name__ == '__main__':
    print(f'review10: seed {SEED}, runs {RUNS}, binary {BIN}')
    t0 = time.time()
    try:
        for fn in SECTIONS:
            if ONLY and fn.__name__ not in ONLY:
                continue
            fn()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'review10: {time.time() - t0:.0f} s, fails {len(FAILS)}')
