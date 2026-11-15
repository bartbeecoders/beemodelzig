#!/usr/bin/env python3
"""Review 11's object references in a .bee file, standalone:

  * s_anim: an animation channel of a deleted object keeps the object's uid
    (OB_UID, not 0x80000000 | a session id): deleted after a duplicate,
    deleted and saved twice, the file opened again and a cylinder added (a
    new uid, not the deleted one's), an object made, keyed and deleted in the
    session, delete and undo / redo, a channel naming a uid the file has no
    object for (garbage too) read and written back as it is.
  * s_parent: a deleted parent's children keep its uid in PRNT and follow
    nothing (they stay where they are, and do not follow the grandparent
    either): PRNT and the world transforms after the parent moves, the file
    opened again, parent_clear on such a child, a duplicate of one,
    parent_set again, delete and undo / redo, a file's PRNT naming a missing
    uid, a loop: read cleanly, nothing infinite.
  * s_lcam: LCAM has a record only for the lights and cameras light.set /
    camera.set (or the properties fields) set, in the order they were first
    set, none for a default scene; save, open, save keeps them; failed and
    partial commands; undo; damaged chunks (a count past the size, past 256,
    NaN values) read cleanly; the Spot button writes the record light.set
    type spot makes, and undo takes it back.

    python3 tests/review11.py BIN [runs=20] [seed]

BEE_CPU (default 14) pins the program; RV_ONLY=s_anim,s_parent,s_lcam runs some.
"""
import math, os, random, shutil, struct, subprocess, sys, tempfile

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
T = tempfile.mkdtemp(prefix='beerv11-', dir='/tmp')
ENV = dict(os.environ, HOME=T)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def make(code, timeout=900):
    """A BeeScript run by BeeModel (--run): its output."""
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
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = None
    lg = open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''
    return rc, lg


def pargs(steps):
    a = []
    for x in steps:
        if x.startswith('!'):
            continue
        a += ['--select', x[1:]] if x.startswith('@') else ['--op', x]
    return a


def run(name, steps, pre=None):
    """The steps run headless after opening `pre`, then saved: (exit code, the file)."""
    fp = f'{T}/{name}_p.bee'
    if os.path.exists(fp):
        os.remove(fp)
    rc, _ = port(*(['--op', f'file.open {pre}'] if pre else []), *pargs(steps), '--op', f'file.save_as {fp}')
    return rc, fp


def objs(f):
    """World transforms by object."""
    return [(o['name'], o['loc'] + o['rot'] + o['scl'], o['type']) for o in beefile.objects(f)]


def where(f, name):
    return next((x[1] for x in objs(f) if x[0] == name), None)


def near(a, b, tol=1e-5):
    return a is not None and b is not None and all(abs(p - q) <= tol for p, q in zip(a, b))


def uids(f):
    c = beefile.chunk(f, b'UIDS')
    if c is None:
        return ()
    n = struct.unpack_from('<I', c)[0]
    return struct.unpack_from(f'<{n}I', c, 4) if len(c) >= 4 + 4 * n else ()


def prnt(f):
    c = beefile.chunk(f, b'PRNT')
    if c is None:
        return ()
    n = struct.unpack_from('<I', c)[0]
    return struct.unpack_from(f'<{n}I', c, 4) if len(c) >= 4 + 4 * n else ()


def ok_file(rc, f, what):
    """BeeModel ran cleanly and the file reads back with finite transforms."""
    try:
        good = rc == 0 and os.path.exists(f) and all(math.isfinite(v) for x in objs(f) for v in x[1])
    except Exception as e:
        good = False
        what += f' ({e})'
    check(good, f'{what}: ran cleanly ({rc}), the file reads back, transforms finite')
    return good


def resaved(f, what, tags=('UIDS', 'PRNT', 'LCAM', 'ANIM')):
    """Opened and saved again with nothing done: the same chunks."""
    g = f[:-4] + '_re.bee'
    rc, _ = port('--op', f'file.open {f}', '--op', f'file.save_as {g}')
    bad = [t for t in tags if not os.path.exists(g) or beefile.chunk(f, t.encode()) != beefile.chunk(g, t.encode())]
    check(rc == 0 and not bad, f'{what}: opened and saved again, the same {"/".join(tags)} ({bad})')


def hx(b):
    return b.hex() if b is not None else None


def rebuild(src, dst, **repl):
    """src's chunks, uncompressed, some replaced (tag=bytes) or dropped (tag=None)."""
    d = open(src, 'rb').read()
    out = [d[:8]]
    for t, b in beefile.chunks(src):
        k = t.decode()
        if k in repl:
            b = repl[k]
            if b is None:
                continue
        out.append(t + struct.pack('<I', len(b)) + b)
    open(dst, 'wb').write(b''.join(out))


# ---- an animated object deleted -------------------------------------------------------------

def s_anim():
    print('-- an animation channel of a deleted object keeps its uid --')
    fx = f'{T}/anim_fix.bee'
    make(f'add("sphere")\nkey("Sphere:x", 1, 0)\nkey("Sphere:x", 10, 3)\nkey("Sphere:rz", 5, 1)\nop("file.save_as", "{fx}")')
    a = beefile.chunk(fx, b'ANIM') if os.path.exists(fx) else None
    at = [i for i in range(0, len(a or b'') - 4, 4) if a[i:i + 4] == b'\x04\0\0\0']
    check(a is not None and len(at) >= 2 and 4 in uids(fx), f'the fixture: Sphere (uid 4) keyed, its channels name uid 4 at {at[:4]}')
    if a is None or not at:
        return
    chan = lambda f: [beefile.chunk(f, b'ANIM')[p:p + 4] for p in at] if os.path.exists(f) and beefile.chunk(f, b'ANIM') else None
    rc, fp = run('dup_del', ['@Camera,Light,Cube,Sphere', 'object.duplicate', '@Sphere', 'object.delete'], fx)
    if ok_file(rc, fp, 'all duplicated, Sphere deleted'):
        check(chan(fp) == [b'\x04\0\0\0'] * len(at), f'the channels still name uid 4 ({chan(fp)})')
        check(4 not in uids(fp), f'and no object has uid 4 now ({uids(fp)})')
    rc, fp = run('del', ['@Sphere', 'object.delete'], fx)
    if ok_file(rc, fp, 'Sphere deleted'):
        check(chan(fp) == [b'\x04\0\0\0'] * len(at), 'the channels still name uid 4')
        resaved(fp, 'Sphere deleted')
        rc2, fp2 = run('del_again', ['create.cylinder'], fp)
        if ok_file(rc2, fp2, 'that file opened again, a cylinder added'):
            u = uids(fp2)
            check(chan(fp2) == [b'\x04\0\0\0'] * len(at) and 4 not in u and len(set(u)) == len(u), f'the cylinder has a new uid, not 4 ({u}), the channels still 4')
    rc, fp = run('session', ['create.sphere', 'anim.key Sphere:x 1 0', 'anim.key Sphere:x 10 3', 'anim.key Sphere:z 4 1', '@Sphere', 'object.delete', 'create.cylinder', 'anim.key Cylinder:y 2 2'])
    if ok_file(rc, fp, 'a sphere made, keyed and deleted (never saved), a cylinder keyed after it'):
        u = uids(fp)
        check(len(set(u)) == len(u) and len(u) == len(objs(fp)), f'one uid per object, all distinct ({u})')
        resaved(fp, 'that session')
    # undo and redo
    rc, ref = run('anim_ref', [], fx)
    rc, refd = run('anim_refd', ['@Sphere', 'object.delete'], fx)
    for name, steps, want, what in (('undo', ['@Sphere', 'object.delete', 'edit.undo'], ref, 'as the file'),
                                    ('redo', ['@Sphere', 'object.delete', 'edit.undo', 'edit.redo'], refd, 'as deleted'),
                                    ('undo2', ['@Sphere', 'object.delete', 'create.cube', 'edit.undo', 'edit.undo', '@Sphere', 'object.delete', 'create.cube'], None, '')):
        rc, fp = run('anim_' + name, steps, fx)
        if not ok_file(rc, fp, ' '.join(steps)):
            continue
        if want:
            bad = [t for t in ('UIDS', 'PRNT', 'ANIM') if beefile.chunk(fp, t.encode()) != beefile.chunk(want, t.encode())]
            check(not bad and objs(fp) == objs(want), f'{" ".join(steps)}: {what} ({bad})')
        else:
            u = uids(fp)
            check(chan(fp) == [b'\x04\0\0\0'] * len(at) and 4 not in u and len(set(u)) == len(u), f'{" ".join(steps)}: the channels name 4, uids distinct ({u})')
    # a channel naming a uid the file has no object for: written back as it is
    rng = random.Random(SEED)
    for k, u in enumerate([77, 0x80000004, 0xffffffff, 2, 3] + [rng.randrange(1, 1 << 32) for _ in range(max(1, RUNS // 5))]):
        b = bytearray(a)
        for p in at:
            b[p:p + 4] = struct.pack('<I', u)
        src = f'{T}/anim_bad{k}.bee'
        rebuild(fx, src, ANIM=bytes(b))
        rc, fp = run(f'anim_bad{k}', ['@Camera,Light,Cube,Sphere', 'object.duplicate', '@Sphere', 'object.delete'], src)
        if ok_file(rc, fp, f'the channels name {u:#x}: opened, duplicated, Sphere deleted, saved'):
            check(chan(fp) == [struct.pack('<I', u)] * len(at), f'  {u:#x} written back as it is ({chan(fp)[:2]})')


# ---- a deleted parent ------------------------------------------------------------------------

def s_parent():
    print('-- a deleted parent: its children keep its uid and follow nothing --')
    fx = f'{T}/par_fix.bee'
    # Cube <- Sphere <- Cylinder, the cube keyed (frame 10 moves it)
    make(f'add("sphere")\nadd("cylinder")\nop("object.parent_set", "Sphere Cube")\nop("object.parent_set", "Cylinder Sphere")\n'
         f'key("Cube:x", 1, 0)\nkey("Cube:x", 10, 4)\nkey("Cube:rz", 10, 0.5)\nop("file.save_as", "{fx}")')
    pr = beefile.chunk(fx, b'PRNT') if os.path.exists(fx) else None
    check(pr is not None and struct.unpack('<6I', pr) == (5, 0, 0, 0, 3, 4), f'the fixture: Sphere (4) under Cube (3), Cylinder (5) under Sphere ({hx(pr)})')
    if pr is None:
        return
    rc, f0 = run('pfix10', ['anim.frame 10'], fx)
    check(rc == 0 and not near(where(f0, 'Cylinder'), where(fx, 'Cylinder')), 'the fixture at frame 10: the cube moves, Cylinder with it')
    rc, fp = run('pdel', ['@Sphere', 'object.delete'], fx)
    if ok_file(rc, fp, 'Sphere deleted'):
        check(prnt(fp) == (0, 0, 0, 4), f'Cylinder\'s parent stays uid 4: PRNT {prnt(fp)}')
        resaved(fp, 'Sphere deleted', tags=('UIDS', 'PRNT'))
    rc, fq = run('pdel_frame', ['@Sphere', 'object.delete', 'anim.frame 10'], fx)
    if ok_file(rc, fq, 'Sphere deleted, then frame 10'):
        check(near(where(fq, 'Cylinder'), where(fp, 'Cylinder')) and not near(where(fq, 'Cube'), where(fp, 'Cube')),
              'the cube moves, Cylinder stays where it is (the grandparent is not its parent)')
        rc, fr = run('pdel_re', ['anim.frame 10'], fp)
        check(rc == 0 and objs(fr) == objs(fq) and prnt(fr) == prnt(fq), 'such a file opened again, frame 10: the same')
    for name, steps, what, test in (
            ('pclear', ['@Sphere', 'object.delete', '@Cylinder', 'object.parent_clear'], 'parent_clear on the child: 0', lambda f: prnt(f) == (0, 0, 0, 0)),
            ('pdup', ['@Sphere', 'object.delete', '@Cylinder', 'object.duplicate'], 'the child duplicated: the copy has no parent', lambda f: len(prnt(f)) == 5 and prnt(f)[4] == 0),
            ('pdel_top', ['@Cube', 'object.delete', 'anim.frame 10'], 'Cube deleted: Sphere keeps uid 3, Cylinder still follows Sphere', lambda f: prnt(f)[-2:] == (3, 4)),
            ('pset', ['@Sphere', 'object.delete', 'object.parent_set Cylinder Cube', 'anim.frame 10'], 'parent_set to the cube again: it follows',
             lambda f: prnt(f)[-1] == 3 and not near(where(f, 'Cylinder'), where(fp, 'Cylinder'))),
            ('pdel_both', ['@Sphere,Cube', 'object.delete'], 'Sphere and Cube deleted together: Cylinder keeps 4', lambda f: prnt(f)[-1:] == (4,))):
        rc, f = run(name, steps, fx)
        if ok_file(rc, f, ' '.join(steps)):
            check(test(f), f'{what} (PRNT {prnt(f)})')
    for name, steps, want, what in (('undo', ['@Sphere', 'object.delete', 'edit.undo', 'anim.frame 10'], f0, 'as the file at frame 10'),
                                    ('redo', ['@Sphere', 'object.delete', 'edit.undo', 'edit.redo', 'anim.frame 10'], fq, 'as deleted at frame 10'),
                                    ('clear_undo', ['@Sphere', 'object.delete', '@Cylinder', 'object.parent_clear', 'edit.undo', 'edit.undo', 'anim.frame 10'], f0, 'as the file at frame 10')):
        rc, f = run('par_' + name, steps, fx)
        if ok_file(rc, f, ' '.join(steps)):
            check(prnt(f) == prnt(want) and uids(f) == uids(want) and all(x[0] == y[0] and near(x[1], y[1]) for x, y in zip(objs(f), objs(want))) and len(objs(f)) == len(objs(want)),
                  f'{" ".join(steps)}: {what}')
    # a file's PRNT naming a uid with no object, a loop, itself
    for k, (vals, what) in enumerate((((0, 0, 0, 3, 2), 'a light as a parent'),
                                      ((0, 0, 0, 5, 4), 'Sphere and Cylinder each other\'s parent'),
                                      ((0, 0, 0, 4, 5), 'each its own parent'),
                                      ((0, 0, 0, 3, 9), 'Cylinder under uid 9 (no object; past the next id)'),
                                      ((0, 0, 0, 3, 0xdeadbeef), 'Cylinder under 0xdeadbeef'))):
        src = f'{T}/par_bad{k}.bee'
        rebuild(fx, src, PRNT=struct.pack('<6I', 5, *vals))
        rc, f = run(f'par_bad{k}', ['anim.frame 10'], src)
        ok_file(rc, f, f'{what}: read, frame 10, saved')
        if k == 3:
            rc, f = run('par_bad_new', ['create.cube'], src)
            u = uids(f) if os.path.exists(f) else ()
            check(rc == 0 and u and 9 not in u and len(set(u)) == len(u), f'and a cube added: it is not given uid 9 (uids {u})')


# ---- light and camera records -----------------------------------------------------------------

def lc(f):
    c = beefile.chunk(f, b'LCAM')
    if c is None:
        return None
    n = struct.unpack_from('<I', c, 4)[0]
    return struct.unpack_from('<I', c)[0], [struct.unpack_from('<I7f', c, 8 + 32 * k) for k in range(min(n, (len(c) - 8) // 32))]


def lc_ok(f, one_each=True):
    """LCAM whole: as many records as it says (one per object)."""
    c = beefile.chunk(f, b'LCAM')
    if c is None or len(c) < 8:
        return False
    n = struct.unpack_from('<I', c, 4)[0]
    us = [r[0] for r in lc(f)[1]]
    return len(c) == 8 + 32 * n and (len(set(us)) == len(us) or not one_each)


def s_lcam():
    print('-- LCAM: records only for what light.set / camera.set set --')
    rc, fp = run('lc_default', [])
    check(rc == 0 and os.path.exists(fp) and beefile.chunk(fp, b'LCAM') == bytes(8), 'the default scene: its LCAM is 00000000 00000000')
    cases = [
        ('power', ['@Light', 'light.set power 3'], [2]),
        ('all', ['@Camera', 'camera.set active', '@Light', 'light.set color 0.3 0.2 2', 'light.set type spot', 'light.set size 0.25', 'light.set angle 30', 'light.set power -1'], None),
        ('bad', ['@Light', 'light.set bogus', '@Camera', 'camera.set lens 0.5', 'camera.set lens 35x', 'camera.set', '@Cube', 'light.set power 2', 'light.set type moon'], None),
        ('partial', ['@Light', 'light.set color 0.5 x', 'light.set size', 'light.set angle -3'], None),
        ('dup', ['@Light', 'light.set power 4', 'object.duplicate', 'light.set power 5', '@Light', 'object.delete', 'object.duplicate'], None),
        ('del_cam', ['@Camera', 'camera.set active', 'camera.set lens 85', '@Light', 'light.set type sun', 'object.delete', '@Camera', 'object.delete'], [1, 2]),
        ('new', ['create.light', 'light.set type area', 'create.camera', 'camera.set lens 20', 'camera.set active', 'object.duplicate', 'camera.set active', 'create.light'], None),
        ('order', ['@Light', 'light.set size 2', '@Camera', 'camera.set lens 30', '@Light', 'light.set power 2', '@Camera', 'camera.set active'], [2, 1]),
    ]
    files = {}
    for name, steps, want in cases:
        rc, fp = run('lc_' + name, steps)
        files[name] = fp
        if not ok_file(rc, fp, ' '.join(steps)):
            continue
        got = [r[0] for r in lc(fp)[1]] if lc(fp) else None
        check(lc_ok(fp) and (want is None or got == want), f'{name}: LCAM whole, one record per object{f", for uids {want} in that order" if want else ""} ({got})')
        if name == 'del_cam':
            check(lc(fp)[0] == 1, f'the camera that renders kept as its uid though deleted ({lc(fp)[0]})')
        if name in ('all', 'del_cam', 'new'):
            resaved(fp, name, tags=('UIDS', 'LCAM'))
            rc2, fp2 = run(f'lc_re_{name}', ['create.light', 'object.duplicate'], fp)
            check(rc2 == 0 and lc_ok(fp2) and lc(fp2)[1] == lc(fp)[1], f'"{name}" opened again, a light added and duplicated: no record for them')
    # undo
    run('lc_bogus', ['@Light', 'light.set bogus'])
    for name, steps, want in (('undo', ['@Light', 'light.set power 3', 'edit.undo'], 'lc_default'),
                              ('undo2', ['@Light', 'light.set power 3', 'light.set type spot', 'edit.undo'], 'power'),
                              ('redo', ['@Light', 'light.set power 3', 'edit.undo', 'edit.redo'], 'power'),
                              ('bad_undo', ['@Light', 'light.set bogus', '@Camera', 'camera.set lens 20', 'edit.undo'], 'lc_bogus'),
                              ('del_undo', ['@Light', 'light.set power 3', 'object.delete', 'edit.undo', 'object.duplicate', 'edit.undo'], 'power'),
                              ('active_undo', ['@Camera', 'camera.set active', 'object.delete', 'edit.undo', 'edit.undo'], 'lc_default')):
        rc, fp = run('lc_' + name, steps)
        w = files.get(want) or f'{T}/{want}_p.bee'
        if ok_file(rc, fp, ' '.join(steps)):
            check(beefile.chunk(fp, b'LCAM') == beefile.chunk(w, b'LCAM'), f'{" ".join(steps)}: LCAM as {want.replace("lc_", "")}\'s ({hx(beefile.chunk(fp, b"LCAM"))[:40]})')
    # a failed light.set that changed something (a colour cut short): no step
    # of its own, so undo takes it back with the step before
    act = f'{T}/lc_active.bee'
    make(f'select("Light")\nop("file.save_as", "{act}")')
    got = {}
    for name, lines in (('con_ref', ['light.set power 3', 'light.set color 0.5 x']),
                        ('con_undo', ['light.set power 3', 'light.set color 0.5 x', 'edit.undo']),
                        ('con_undo2', ['light.set power 3', 'light.set color 0.5 x', 'light.set size 2', 'edit.undo'])):
        fp = f'{T}/lc_{name}_p.bee'
        rc, _ = port('--op', f'file.open {act}', '--select', 'Light', *[a for x in lines for a in ('--op', x)], '--op', f'file.save_as {fp}')
        got[name] = beefile.chunk(fp, b'LCAM') if rc == 0 and os.path.exists(fp) else None
    check(got['con_ref'] and len(got['con_ref']) == 40, f'power 3 and a colour cut short: one record ({hx(got["con_ref"])})')
    check(got['con_undo'] == bytes(8), f'undone: both go, no record ({hx(got["con_undo"])})')
    check(got['con_undo2'] == got['con_ref'], 'a size after them, undone: the record as before the size')
    # damaged chunks: read cleanly, saved again whole
    base = files['all']
    good = beefile.chunk(base, b'LCAM')
    recs = [good[8 + 32 * k:8 + 32 * (k + 1)] for k in range(2)]
    nan = struct.pack('<I', 2) + struct.pack('<f', float('nan')) + struct.pack('<3f', -1, 1e30, float('inf')) + struct.pack('<I', 7) + struct.pack('<2f', -5, float('nan'))
    rng = random.Random(SEED + 1)
    dam = [('count past the size', struct.pack('<II', 1, 3) + b''.join(recs)),
           ('a cut record', good[:-5]),
           ('300 records', struct.pack('<II', 1, 300) + b''.join([recs[0]] * 150 + [recs[1]] * 150)),
           ('NaN, inf, negative values; type 7', struct.pack('<II', 2, 1) + nan),
           ('records for no object (uids 9, 0)', struct.pack('<II', 9, 2) + struct.pack('<I', 9) + recs[1][4:] + struct.pack('<I', 0) + recs[0][4:]),
           ('the cube as the camera', struct.pack('<II', 3, 1) + struct.pack('<I', 3) + recs[0][4:]),
           ('empty', b''),
           ('4 bytes', b'\1\0\0\0')]
    for _ in range(max(1, RUNS // 5)):
        b = bytearray(good)
        for _ in range(rng.randrange(1, 6)):
            b[rng.randrange(len(b))] = rng.randrange(256)
        dam.append(('random bytes', bytes(b)))
    for k, (what, c) in enumerate(dam):
        src = f'{T}/lc_bad{k}.bee'
        rebuild(base, src, LCAM=c)
        rc, fp = run(f'lc_bad{k}', ['@Light', 'object.duplicate'], src)
        if ok_file(rc, fp, f'LCAM damaged ({what}): opened, the light duplicated, saved'):
            check(lc_ok(fp, False) and len(lc(fp)[1]) <= 256, f'  saved whole, 256 records at most ({len(lc(fp)[1]) if lc(fp) else None} records)')
    src = f'{T}/lc_none.bee'
    rebuild(base, src, LCAM=None)
    rc, fp = run('lc_none', ['@Light', 'light.set power 2'], src)
    if ok_file(rc, fp, 'no LCAM chunk at all, then light.set'):
        check(lc_ok(fp) and [r[0] for r in lc(fp)[1]] == [2], f'  one record, the light\'s ({lc(fp)})')
    # the properties' type list: Spot writes what light.set would
    rc, fo = run('lc_spot_ref', ['@Light', 'light.set type spot'])
    fp = f'{T}/lc_spot_ui.bee'
    port('--select', 'Light', '--click-label', 'enum:Point', '--click-label', 'menuitem:Spot', '--op', f'file.save_as {fp}')
    check(os.path.exists(fp) and beefile.chunk(fo, b'LCAM') == beefile.chunk(fp, b'LCAM') and beefile.chunk(fp, b'LCAM') != bytes(8),
          f'the type list, Spot: the record light.set type spot makes ({hx(beefile.chunk(fp, b"LCAM")) if os.path.exists(fp) else None})')
    fp2 = f'{T}/lc_spot_undo.bee'
    port('--select', 'Light', '--click-label', 'enum:Point', '--click-label', 'menuitem:Spot', '--op', 'edit.undo', '--op', f'file.save_as {fp2}')
    check(os.path.exists(fp2) and beefile.chunk(fp2, b'LCAM') == bytes(8), f'and undone: no record ({hx(beefile.chunk(fp2, b"LCAM")) if os.path.exists(fp2) else None})')
    fp3 = f'{T}/lc_same.bee'
    port('--select', 'Light', '--click-label', 'enum:Point', '--click-label', 'menuitem:Point', '--select', 'Camera', '--op', f'file.save_as {fp3}')
    check(os.path.exists(fp3) and beefile.chunk(fp3, b'LCAM') == bytes(8), 'the type list, Point on a point light: nothing set, no record')


SECTIONS = [s_anim, s_parent, s_lcam]

if __name__ == '__main__':
    print(f'review11: seed {SEED}, runs {RUNS}, binary {BIN}')
    try:
        for fn in SECTIONS:
            if ONLY and fn.__name__ not in ONLY:
                continue
            fn()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'review11 fails {len(FAILS)}')
