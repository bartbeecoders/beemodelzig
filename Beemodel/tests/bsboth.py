"""Shared by tests/bs_cad.py, bs_sketch.py, bs_sdf.py, bs_model.py: BeeScript
run by BeeModel (--eval / --run, a temp HOME and XDG_RUNTIME_DIR each).

Standalone (the default since 2026-11-14, when BeeModel stopped being a port):
each script must give a clean result or a clean script error (exit 0 or 1, no
crash, panic or timeout), and every scene it saves must read back as a .bee
file. Given the assembly original as ORIG (legacy), the two are compared as
they used to be: exit code, printed output and the saved scenes.

    import bsboth as B
    B.setup(sys.argv)          # BIN ORIG RUNS [seed]
    B.same('print(pad(...))')
    B.files('...op("file.save", "@OUT")', 'tag', 'what')
    B.finish('bs_cad')
"""
import os, random, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401
import beefile

ROOT = os.path.dirname(HERE)
BIN = ORIG = None
RUNS = 100
SEED = 0
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
T = None
NCHECK = [0]


def setup(argv, default_runs=100):
    global BIN, ORIG, RUNS, SEED, T
    BIN = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
    ORIG = os.path.abspath(argv[2]) if len(argv) > 2 and argv[2] not in ('', '-') else None
    if ORIG is not None and not os.path.exists(ORIG):
        ORIG = None
    RUNS = int(argv[3]) if len(argv) > 3 else default_runs
    SEED = int(argv[4]) if len(argv) > 4 else random.randrange(1 << 30)
    T = tempfile.mkdtemp(prefix='beebsc-', dir='/tmp')
    random.seed(SEED)
    mode = f'against {ORIG}' if ORIG else 'standalone'
    print(f'{os.path.basename(argv[0])}: {BIN} {mode}, runs {RUNS}, seed {SEED}', flush=True)


def check(cond, msg):
    NCHECK[0] += 1
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def run(binary, args, timeout=120):
    """One run, pinned, with a HOME and XDG_RUNTIME_DIR of its own, run inside it
    (random path words like "subsurf" or "1" land there, not in the project): (rc, stdout)."""
    h = tempfile.mkdtemp(dir=T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'))
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary, *args], capture_output=True, timeout=timeout, env=env, cwd=h)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout')
    shutil.rmtree(h, True)
    return out


def clean(r):
    """A run that ended as a program should: a result or a script error, no
    crash (a signal), panic, safety check or timeout."""
    rc, out = r
    return rc in (0, 1) and 'panic' not in out and 'reached unreachable' not in out and 'integer overflow' not in out


def both(code, timeout=120):
    return run(ORIG, ['--eval', code], timeout), run(BIN, ['--eval', code], timeout)


def same(code, what=None, timeout=120, quiet=False):
    """The same exit code and output from both: (ok, original's).
    Standalone: a clean run of BeeModel: (ok, its result)."""
    if ORIG is None:
        b = run(BIN, ['--eval', code], timeout)
        ok = clean(b)
        if not quiet or not ok:
            check(ok, (what or repr(code[:90])) + ('' if ok else f'\n         {b!r}'))
        return ok, b
    a, b = both(code, timeout)
    ok = a == b and a[0] is not None
    if not quiet or not ok:
        check(ok, (what or repr(code[:90])) + ('' if ok else f'\n         original {a!r}\n         port     {b!r}'))
    return ok, a


def scene(path):
    """A .bee file's scene as both writers can be compared (as tests/bscript.py):
    every chunk but the workspaces, the thumbnail and the view; meshes taken
    through the objects that use them."""
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<I', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        me = meshes[mi] if typ == 0 and mi < len(meshes) else None
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], me))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL') or not b:
            continue
        rest.setdefault(t, []).append(b)
    return recs, rest


def same_scene(pa, pb, what, quiet=False):
    if not (os.path.exists(pa) and os.path.exists(pb)):
        check(False, f'{what}: a file is missing (original {os.path.exists(pa)}, port {os.path.exists(pb)})')
        return False
    (ra, xa), (rb, xb) = scene(pa), scene(pb)
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        if a[0] != b[0]:
            fa, fb = beefile.objects(pa)[k], beefile.objects(pb)[k]
            why.append(f'object {k} {fa["name"]!r}: {[(x, fa[x], fb[x]) for x in fa if x != "mesh" and fa[x] != fb[x]]}')
        elif a[1] != b[1]:
            why.append(f'object {k}: its mesh ({len(a[1] or b"")} / {len(b[1] or b"")} bytes)')
    for t in sorted(set(xa) | set(xb)):
        if xa.get(t) != xb.get(t):
            why.append(f'{t.decode()} chunk')
    if not quiet or why:
        check(not why, f'{what}: the same scene' + ('' if not why else ': ' + '; '.join(why[:4])))
    return not why


def files(code, tag, what, quiet=False):
    """The script in both, each saving @OUT: the same output and scene.
    Standalone: a clean run, and a scene that reads back if it saved one."""
    pa, pb = f'{T}/{tag}_o.bee', f'{T}/{tag}_p.bee'
    if ORIG is None:
        b = run(BIN, ['--eval', code.replace('@OUT', pb)])
        ok = clean(b)
        why = '' if ok else f' ({b!r})'
        if ok and os.path.exists(pb):
            try:
                scene(pb)
            except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
                ok, why = False, f': its .bee does not read back ({e})'
        elif ok and b[0] == 0 and '@OUT' in code:
            ok, why = False, ': no file saved'
        if not quiet or not ok:
            check(ok, f'{what}: runs cleanly' + why)
        return ok
    a = run(ORIG, ['--eval', code.replace('@OUT', pa)])
    b = run(BIN, ['--eval', code.replace('@OUT', pb)])
    ok = a == b and a[0] is not None
    if not quiet or not ok:
        check(ok, f'{what}: the same output' + ('' if ok else f' (original {a!r} / port {b!r})'))
    # (a script that stops with the same error before its save, in both: the same, no files)
    if ok and a[0] == 1 and 'error:' in a[1] and not os.path.exists(pa) and not os.path.exists(pb):
        return True
    return same_scene(pa, pb, what, quiet) and ok


def table(area_names):
    """{name: (min, max)} of the builtins in these areas (bs_table.zig)."""
    import re
    rows = re.findall(r'\.name = "([a-z_0-9]+)", \.min = (\d+), \.max = (\d+), \.area = \.(\w+)', open(os.path.join(ROOT, 'src', 'bs_table.zig')).read())
    return {n: (int(a), int(b)) for n, a, b, ar in rows if ar in area_names}


def argcounts(names, prefix=''):
    """Each argument count (one too few, each allowed one, one too many) of
    each builtin, with junk values: the same words from both."""
    bad = []
    vals = ['"S"', '1', 'nil', '"x"', '-1', '"Cube"', '0.5', '"1e40"']
    for nm, (mn, mx) in sorted(names.items()):
        for n in range(max(0, mn - 1), mx + 2):
            for v0 in range(2):
                args = ', '.join(vals[(k + v0 * 3) % len(vals)] for k in range(n))
                code = f'{prefix}print({nm}({args}))'
                if ORIG is None:
                    b = run(BIN, ['--eval', code])
                    if not clean(b):
                        bad.append((code, b))
                    continue
                a, b = both(code)
                if a != b or a[0] is None:
                    bad.append((code, a, b))
    what = 'answered cleanly' if ORIG is None else 'the same words'
    check(not bad, f'{len(names)} builtins, every argument count with junk values: {what}' + (f': {bad[:3]}' if bad else ''))


def finish(name):
    shutil.rmtree(T, True)
    print(f'{name}: checks {NCHECK[0]}, fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
