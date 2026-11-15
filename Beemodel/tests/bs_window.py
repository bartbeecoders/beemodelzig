#!/usr/bin/env python3
"""The phase 12 area builtins typed into the console of BeeModel's window
(tests/wl_fake.py, the fake compositor): materials and node graphs, geometry
node trees, UVs, vertex paint and a sculpt stroke, folders, curves, an
L-system, text. After each area the scene saved must read back, and opened
and saved again be the same. Each typed line that changes the scene is one
undo step: Ctrl+Z goes back through the scenes saved after each line, as
often as there were lines takes it back to the start; Ctrl+Shift+Z as
often, to the end. The window must keep working throughout. The console's
screenshot is kept for the eye.

    python3 tests/bs_window.py BIN

BEE_CPU (default 10) pins the window.
"""
import os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import temphome  # noqa: F401
argv = sys.argv
sys.argv = [argv[0], argv[1] if len(argv) > 1 and argv[1] else os.path.join(ROOT, 'zig-out-debug/bin/beemodel')]
BIN = os.path.abspath(sys.argv[1])
import bscript as B  # (its window: PortWin)
import beefile
CV_HDR, CP_SZ = 572, 48  # (tests/bs_proc.py: a CURV record's header and point)
FAILS = []
T = tempfile.mkdtemp(prefix='beebswin-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def called(code):
    return set(re.findall(r'\b([a-z_][a-z0-9_]*)\s*\(', code))


def ported_set():
    """The builtins BeeModel has (bs_*.zig's lists)."""
    names = set()
    for f in os.listdir(os.path.join(ROOT, 'src')):
        if f.startswith('bs_') and f.endswith('.zig') and f not in ('bs_table.zig', 'bs_areas.zig'):
            names |= set(re.findall(r'\.name = "([a-z_0-9]+)"', open(os.path.join(ROOT, 'src', f)).read()))
    return names


def all_builtins():
    return set(re.findall(r'\.name = "([a-z_0-9]+)", \.min', open(os.path.join(ROOT, 'src', 'bs_table.zig')).read()))


def scene(path):
    """A .bee file's scene: objects with their meshes, every other chunk but the
    workspaces, thumbnail and view (as tests/bscript.py, but UVs and vertex
    colours kept: one writer, so its mesh order holds)."""
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<I', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        recs.append((r[:32].split(b'\0')[0].ljust(32, b'\0') + r[32:80], meshes[mi] if typ == 0 and mi < len(meshes) else None))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW') or not b:
            continue
        rest.setdefault(t, []).append(b)
    return recs, rest


def scene_diff(pa, pb, skip=()):
    """'' when both files hold the same scene, else why not. skip: chunks left
    out (undone: UIDS's next uid is not part of a step)."""
    ea, eb = os.path.exists(pa), os.path.exists(pb)
    if not (ea and eb):
        return f'a file is missing ({os.path.basename(pa)} {ea}, {os.path.basename(pb)} {eb})'
    try:
        (ra, xa), (rb, xb) = scene(pa), scene(pb)
    except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
        return f'a file does not read back ({e})'
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        if a != b:
            why.append(f'object {k}')
    for t in sorted((set(xa) | set(xb)) - set(skip)):
        if xa.get(t, []) != xb.get(t, []):
            why.append(f'{t.decode()} chunk')
    return '; '.join(why[:4])


def reads_back(path, what):
    """The saved scene reads back; opened and saved again, the same scene."""
    again = path[:-4] + '_again.bee'
    h = tempfile.mkdtemp(dir=T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'))
    r = subprocess.run([BIN, '--eval', f'op("file.open", "{path}")\nop("file.save", "{again}")'], capture_output=True, timeout=300, env=env, cwd=h)
    d = scene_diff(path, again) if r.returncode == 0 else f'opened and saved again: exit {r.returncode} {r.stdout[-200:]!r}'
    check(not d, f'{what}: read back, opened and saved again the same scene' + ('' if not d else ': ' + d))


import shutil

K_ESC = 1

RUNS = [  # one line per run (short enough for the console's input field; each changes the scene: one step)
    ('materials', ['m = material("W"); matset(m, "base", 0.9, 0.1, 0.1); assign("Cube", m)', 'i = instance(m, "WI"); matset(m, "roughness", 0.3)']),
    ('a shader graph', ['n = node("W", "noise", 4); k = node("W", "scalarparam", "Wear", 0.6)', 'x = node("W", "mix", 2); link("W", n, x, 2); socket("W", "base", x)',
                        'socket("W", "roughness", k); matparam("WI", "Wear", 0.2)', 'print(nodeinfo("W", 0, "count"), nodeval("W", x, 0, 0.3, 0.2, 0.1)); set("Cube", "y", 0.1)']),
    ('a geometry node tree', ['t = gtree("G"); a = gnode(t, "grid", 3, 3); b = gnode(t, "transform")', 'glink(t, a, b, 1); gset(t, b, 4, 2); print(t, ginfo(t, 0, "count"))']),
    ('UVs', ['print(unwrap("Cube"), seams("Cube", "sharp"))', 'uvmap("Cube", 2, 2, 0.5, 0); print(uvstat("Cube", "islands"))']),
    ('vertex paint', ['print(vpaint("Cube", 1, 1, 1, 1.5, 255, 0, 0), vcol("Cube", 0, 0), vcol("Cube", 6, 0))']),
    ('a sculpt stroke', ['add("sphere", "Ball", 3, 0, 0)', 'print(sculpt("Ball", "draw", 3, 1, 0, 3, 1, 0.5, 0.5, 0.5))']),
    ('folders', ['folder("Props"); infolder("Cube", "Props"); print(infolder("Cube"), folders())']),
    ('a curve, an L-system, text', ['c = curve("bezier", "Path"); print(c, cpoints(c))', 'print(lsystem("Tree", "F", "F=F[+F]F[-F]F", 2, 25))', 'set("Cube", "y", 0.3); print(text("Nope"))']),
]


def main():
    print('-- the area builtins in the window\'s console: one undo step a run --')
    have = ported_set()
    every = all_builtins()
    runs = [(w, l) for w, l in RUNS if not (called(' '.join(l)) & every) - have]
    for w, l in RUNS:
        if (w, l) not in runs:
            print(f'  skip {w}: needs {sorted((called(" ".join(l)) & every) - have)}')
    p = B.PortWin()
    try:
        def save(tag):
            p.line(f'file.save_as {T}/{tag}.bee')
            p.key(K_ESC)

        n = 0
        save('l0')
        for k, (what, lines) in enumerate(runs):
            for line in lines:
                p.line(line)
                if k == len(runs) - 1 and line is lines[-1]:
                    p.image().save(f'{T}/con.png')
                p.key(K_ESC)
                n += 1
                save(f'l{n}')
                d = scene_diff(f'{T}/l{n - 1}.bee', f'{T}/l{n}.bee', (b'UIDS',))
                check(d and 'missing' not in d and 'read back' not in d, f'{what}: {line[:60]!r} changed the scene' + ('' if d else ': it did not') + (f' ({d})' if d and ('missing' in d or 'read back' in d) else ''))
            save(f'r{k}')
            reads_back(f'{T}/r{k}.bee', f'after the runs: {what}')
        # each line that changed the scene is one step, back through the same scenes
        for k in range(n - 1, -1, -1):
            p.key(44, 4)
            p.f.pump(0.3)
            save(f'b{k}')
            d = scene_diff(f'{T}/l{k}.bee', f'{T}/b{k}.bee', (b'UIDS',))
            check(not d, f'Ctrl+Z {n - k}: as after line {k}' + ('' if not d else ': ' + d))
        for _ in range(n):
            p.key(44, 5)
            p.f.pump(0.3)
        save('redo')
        d = scene_diff(f'{T}/redo.bee', f'{T}/r{len(runs) - 1}.bee')
        check(not d, f'Ctrl+Shift+Z {n} times: all redone, as after the last run' + ('' if not d else ': ' + d))
        check(p.f.proc.poll() is None, 'the window still running')
        # the console's printed lines
        from PIL import Image
        A = Image.open(f'{T}/con.png')
        check(len(set(A.convert('L').getextrema())) > 1, f'the console drawn: {A.size}, not one colour')
        keep = os.environ.get('BS_KEEP')
        if keep:
            shutil.copy(f'{T}/con.png', f'{keep}/con.png')
        print(f'     (the console: {T}/con.png; its lines are read from the screenshot by eye)')
    finally:
        p.close()
        if os.environ.get('BS_KEEP'):
            shutil.copytree(T, os.path.join(os.environ['BS_KEEP'], 'run'), dirs_exist_ok=True, ignore=shutil.ignore_patterns('p*'))
        shutil.rmtree(T, True)
        shutil.rmtree(getattr(B, 'T', ''), True)
    print(f'... fails {len(FAILS)}')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
