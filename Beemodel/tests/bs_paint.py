#!/usr/bin/env python3
"""BeeScript's paint, UV and sculpt builtins (src/bs_paint.zig: sculpt unwrap
uvpack seams uvstat imgset uvmap paint layer vpaint vcol bake) run by BeeModel
(--eval and --run, a temp HOME and XDG_RUNTIME_DIR each): each script ends
cleanly (its output or one script error, exit 0 or 1, no crash, panic or
timeout), and the .bee file it saves reads back and survives open -> save
with the same scene (meshes, UVs and seams, vertex colours by object; the
embedded images' pixels and paint layers decoded). Every builtin: normal
calls, each argument count, wrong types and bad names in each place, edge
values (NaN, infinities, huge, negative, empty text), random calls; a script
file through --run prints what --eval prints; undo / redo of a run with
strokes in it (headless: one step, everything back); random garbage (no
crash, no hang).

    python3 tests/bs_paint.py BIN [random-runs=60] [seed]

BS_ONLY=calls,counts,types,edges,random,run,corpus,undo,fuzz runs some sections.
"""
import io, os, random, re, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('BS_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beebsp-', dir=os.environ.get('BS_TMP') or None)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(s):
    return not ONLY or s in ONLY


def run(binary, args, timeout=300, home=None):
    """One run with a HOME and XDG_RUNTIME_DIR of its own: (rc, stdout, stderr)."""
    h = home or tempfile.mkdtemp(dir=T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'), XDG_CONFIG_HOME=os.path.join(h, '.config'),
               XDG_DATA_HOME=os.path.join(h, '.local/share'), XDG_STATE_HOME=os.path.join(h, '.local/state'))
    env.pop('WAYLAND_DISPLAY', None)
    try:
        r = subprocess.run([binary, *args], capture_output=True, timeout=timeout, env=env)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout', '')
    if not home:
        shutil.rmtree(h, True)
    return out


# ---- the scene the .bee files hold ------------------------------------------------------

def chunk(path, tag):
    return b''.join(b for t, b in beefile.chunks(path) if t == tag)


def uv_recs(path):
    d, o, out = chunk(path, b'MUVS'), 0, {}
    while o + 12 <= len(d):
        ix, fl, nl = struct.unpack_from('<III', d, o)
        n = 12 + (nl * 8 if fl & 1 else 0) + (((nl + 3) & ~3) if fl & 2 else 0)
        out[ix] = d[o:o + n][4:]
        o += n
    return out


def vcol_recs(path):
    d, o, out = chunk(path, b'MVCL'), 0, {}
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        out[ix] = d[o + 4:o + 8 + n * 4]
        o += 8 + n * 4
    return out


def rgba(png):
    if Image is None:
        return png
    return Image.open(io.BytesIO(png)).convert('RGBA').tobytes()


def images(path):
    d, o, out = chunk(path, b'IMGD'), 0, {}
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        # (RGB: the pixels' colours; tests/paint.py looks at the alpha)
        px = rgba(d[o + 8:o + 8 + n])
        out[ix] = bytes(x for i, x in enumerate(px) if i % 4 != 3)
        o += 8 + n
    return out


def layers(path):
    d, o, out = chunk(path, b'ILAY'), 0, {}
    while o + 12 <= len(d):
        ix, count, active = struct.unpack_from('<III', d, o)
        o += 12
        ls = []
        for _ in range(count):
            op, bl, vis, n = struct.unpack_from('<fIII', d, o)
            ls.append((op, bl, vis, rgba(d[o + 16:o + 16 + n])))
            o += 16 + n
        out[ix] = (active, ls)
    return out


def scene(path):
    """Objects (their record, mesh, UVs, colours, by object: meshes taken
    through the objects that use them), the images' pixels and layers, every
    other chunk but the workspaces, thumbnail and view."""
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    uvs, vcs = uv_recs(path), vcol_recs(path)
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<II', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        me = meshes[mi] if typ == 0 and mi < len(meshes) else None
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], me, uvs.get(mi) if me else None, vcs.get(mi) if me else None))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL', b'IMGD', b'ILAY') or not b:
            continue
        rest.setdefault(t, []).append(b)
    rest['images'] = images(path)
    rest['layers'] = layers(path)
    return recs, rest


def near(a, b, most=2, share=0.02):
    """Baked images: the same but for texels on rays that graze a surface (rows run
    in parallel, tests/uv.py s_bake allows the same): at most 2 of 255, on at
    most 2% of the channels."""
    if set(a) != set(b):
        return False
    for k in a:
        x, y = a[k], b[k]
        if len(x) != len(y):
            return False
        d = [(p, q) for p, q in zip(x, y) if p != q]
        # (or a normal map's 0 +- an ulp: 127 against 128, as when the high mesh
        # is the low one itself: bake.zig's rounding there, not the builtin's)
        if d and not all({p, q} == {127, 128} for p, q in d) and (max(abs(p - q) for p, q in d) > most or len(d) > len(x) * share):
            return False
    return True


def mesh_near(a, b, tol):
    """Two MESH chunks the same but for vertices within tol (sculpt strokes on
    big meshes add their normals up in parallel, atomically: two runs differ
    from each other by an ulp or two)."""
    if a is None or b is None or len(a) != len(b):
        return a == b
    nv = struct.unpack_from('<I', a)[0]
    if a[:12] != b[:12] or a[12 + nv * 12:] != b[12 + nv * 12:]:
        return False
    x, y = struct.unpack_from(f'<{nv * 3}f', a, 12), struct.unpack_from(f'<{nv * 3}f', b, 12)
    return all(p == q or abs(p - q) <= tol for p, q in zip(x, y))


def scene_diff(pa, pb, baked=False, tol=0.0):
    # (tol: a sculpted mesh's ulps, and the maps baked from it a little more)
    most, share = (8, 0.01) if tol > 0 else (2, 0.02)
    if not (os.path.exists(pa) and os.path.exists(pb)):
        return [f'a file is missing (first {os.path.exists(pa)}, second {os.path.exists(pb)})'] if os.path.exists(pa) != os.path.exists(pb) else []
    (ra, xa), (rb, xb) = scene(pa), scene(pb)
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        for what, x, y in (('record', a[0], b[0]), ('mesh', a[1], b[1]), ('UVs', a[2], b[2]), ('colours', a[3], b[3])):
            if x != y and not (what == 'mesh' and tol > 0 and mesh_near(x, y, tol)):
                why.append(f'object {k} {a[0][:32].rstrip(bytes(1)).decode(errors="replace")}: its {what}')
    for t in sorted(set(xa) | set(xb), key=str):
        if t == 'images' and baked and near(xa[t], xb[t], most, share):
            continue
        if t == 'layers' and baked and set(xa[t]) == set(xb[t]) and all(
                xa[t][i][0] == xb[t][i][0] and len(xa[t][i][1]) == len(xb[t][i][1]) and
                all(p[:3] == q[:3] and near({0: p[3]}, {0: q[3]}, most, share) for p, q in zip(xa[t][i][1], xb[t][i][1])) for i in xa[t]):
            continue
        if xa.get(t) != xb.get(t):
            why.append(f'{t if isinstance(t, str) else t.decode()}')
    return why


# ---- one script ------------------------------------------------------------------------------

N = [0]


def crashed(b):
    """Why a run did not end as a program should (a result or one script error), or ''."""
    if b[0] is None:
        return 'timed out'
    if b[0] not in (0, 1) or 'panic' in b[1] + b[2] or 'reached unreachable' in b[2]:
        return f'crashed: rc {b[0]} {(b[1] + b[2])[-300:]!r}'
    return ''


def readback(pp):
    """[] when the saved file reads back and open -> save keeps its scene, else why not."""
    try:
        scene(pp)
    except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
        return [f'its .bee does not read back ({e})']
    p2 = pp[:-4] + '_again.bee'
    r = run(BIN, ['--eval', f'op("file.open", "{pp}")\nop("file.save", "{p2}")'])
    if r[0] != 0 or not os.path.exists(p2):
        return [f'open -> save failed: rc {r[0]} {(r[1] + r[2])[-200:]!r}']
    why = scene_diff(pp, p2)
    os.unlink(p2)
    return ['open -> save changed: ' + '; '.join(why[:4])] if why else []


def port(code, save=True):
    """The script (with a save at the end): ((rc, out, err), why it is not fine)."""
    N[0] += 1
    pp = f'{T}/p{N[0]}.bee'
    b = run(BIN, ['--eval', code + (f'\nop("file.save", "{pp}")' if save else '')])
    if save and b[0] == 0 and not os.path.exists(pp):
        # (once more: a full /tmp - its quota shared with other runs - fails the save)
        print(f'  ---- nothing saved ({b[1][-200:]!r}{b[2][-200:]!r}): again')
        b = run(BIN, ['--eval', code + f'\nop("file.save", "{pp}")'])
    why = [crashed(b)] if crashed(b) else []
    if not why and save:
        if os.path.exists(pp):
            why = readback(pp)
        elif b[0] == 0:
            why = ['no file saved']
    if os.path.exists(pp):
        os.unlink(pp)
    return b, why


def same(code, what, save=True):
    """A clean run; the file it saves reads back, open -> save the same."""
    b, why = port(code, save)
    check(not why, what + ('' if not why else f'\n         {b[:2]!r}\n         ' + '; '.join(why[:4])))
    return b


# A scene to work on: an unwrapped sphere with a material painting into image T,
# a cube over it to bake from, a 32 x 32 image.
PRE = '''op("image.new", "T 32 32")
op("image.new", "U 8 8")
s = add("sphere", "S", 0, 0, 0)
unwrap("S", "smart")
select("S")
op("material.new", "M")
op("material.node", "M image T")
op("material.socket", "M base 1")
h = add("cube", "H", 0, 0, 0)
scale("H", 1.2)
'''

SPECS = {  # name: (min, max, a valid call's arguments)
    'sculpt': (10, 10, ['"S"', '"draw"', '0', '0', '1', '0.2', '0', '1', '0.5', '0.5']),
    'unwrap': (1, 2, ['"S"', '"smart"']),
    'uvpack': (1, 1, ['"S"']),
    'seams': (2, 2, ['"S"', '"sharp"']),
    'uvstat': (2, 2, ['"S"', '"area"']),
    'imgset': (6, 7, ['"T"', '1', '2', '10', '20', '30', '40']),
    'uvmap': (5, 5, ['"S"', '1.5', '0.5', '0.1', '-0.2']),
    'paint': (5, 8, ['"S"', '0', '0', '1', '0.6', '255', '0', '0']),
    'layer': (2, 4, ['"T"', '"opacity"', '1', '0.5']),
    'vpaint': (5, 8, ['"S"', '0', '0', '1', '0.6', '0', '255', '0']),
    'vcol': (3, 3, ['"S"', '0', '1']),
    'bake': (4, 5, ['"S"', '"H"', '"ao"', '"T"', '0.5']),
}


def call(name, args):
    return f'{name}({", ".join(args)})'


def pre_for(name):
    p = PRE
    if name == 'layer':
        p += 'layer("T", "add")\n'
    if name == 'vcol':
        p += 'vpaint("S", 0, 0, 1, 0.8, 10, 200, 30)\n'
    return p


# ---- normal calls ----------------------------------------------------------------------

if want('calls'):
    print('-- normal calls: what they return and do --')
    same(PRE + 'print(uvstat("S", "islands"), uvstat("S", "angle"), uvstat("S", "area"), uvstat("S", "flipped"), uvstat("S", "overlap"), uvstat("S", "inside"))',
         'uvstat: every measure of a smart projection')
    same(PRE + 'print(unwrap("S"), unwrap("S", "smart"), unwrap("S", "lscm"), unwrap("Cube"), unwrap("H", "smart"))', 'unwrap: LSCM, smart, any other word, the cube')
    same(PRE + 'print(seams("S", "sharp"), seams("Cube", "sharp"), unwrap("Cube"), seams("Cube", "none"), seams("S", "none"))', 'seams: sharp, none; then unwrap along them')
    same('print(uvpack("Cube"), uvstat("Cube", "islands"), uvstat("Cube", "area"))', 'uvpack / uvstat on a mesh without UVs: -1')
    same('print(unwrap("Cube"), uvpack("Cube"), uvstat("Cube", "islands"))\nuvmap("Cube", 2, 0.5, 0.25, -1)\nprint(uvstat("Cube", "inside"), uvstat("Cube", "area"))',
         'uvpack after unwrap; uvmap scales and moves every UV')
    same('uvmap("Cube", 2, 2, 0, 0)\nprint(uvstat("Cube", "islands"))', 'uvmap on a mesh without UVs: nothing')
    same('edit("Cube")\nvselect("Cube", 0, 1, 2, 3)\nprint(seams("Cube", "mark"), seams("Cube", "clear"), seams("Cube", "mark"))\nedit()\nprint(unwrap("Cube"), seams("Cube", "clear"))',
         'seams mark / clear between the selected vertices (edit mode)')
    same('vselect("Cube", 0, 1, 2, 3, 4)\nprint(seams("Cube", "mark"), unwrap("Cube"))', 'seams mark with the object-mode selection')
    same(PRE + 'print(imgset("T", 1, 2, 10, 20, 30), imgset("T", 3, 3, -5, 300, 7.9, 128), imgset("T", 31, 31, 1, 2, 3, 0), imgset("T", 32, 0, 1, 2, 3), imgset("T", -1, 0, 1, 2, 3), imgset("T", 0, 32, 9, 9, 9))',
         'imgset: in range, clamped channels, alpha, out of range')
    same(PRE + 'print(layer("T", "count"), layer("T", "add"), layer("T", "count"), layer("T", "active"), layer("T", "active", 0), layer("T", "active"), layer("T", "active", 5))\n'
         'print(layer("T", "opacity", 1, 0.5), layer("T", "opacity", 1, 7), layer("T", "blend", 1, 2), layer("T", "blend", 1, 3), layer("T", "blend", 1, -1), layer("T", "visible", 1, 0))\n'
         'print(layer("T", "remove", 0), layer("T", "add"), layer("T", "remove", 2), layer("T", "count"), layer("T", "merge"), layer("T", "count"), layer("T", "opacity", 0, 1))',
         'layer: every operation, its answers')
    same(PRE + 'layer("T", "add")\nlayer("T", "blend", 1, 1)\nprint(paint("S", 0, 0, 1, 0.7, 0, 0, 255))\nlayer("T", "opacity", 1, 0.25)', 'layer: painting into a layer, saved with its blend')
    same(PRE + 'print(paint("S", 0, 0, 1, 0.6, 255, 0, 0), paint("S", 1, 0, 0, 0.6), paint("S", 0, 1, 0, 0.3, 0, 300, -4), paint("S", 9, 9, 9, 0.1), paint("Cube", 1, 1, 1, 1, 1, 2, 3))',
         'paint: dabs (the brush colour stays), far away, an object without an image')
    same(PRE + 'print(vpaint("S", 0, 0, 1, 0.6, 255, 0, 0), vpaint("S", 0, 0, -1, 0.6), vcol("S", 0, 0), vcol("S", 0, 3))\nn = 0\nfor k in 0..verts("S") { if vcol("S", k, 0) != 255 or vcol("S", k, 1) != 255 { n += 1\n print(k, vcol("S", k, 0), vcol("S", k, 1), vcol("S", k, 2), vcol("S", k, 3)) } }\nprint(n)',
         'vpaint, then vcol of its vertices')
    same('print(vcol("Cube", 0, 0))\nprint(vpaint("Cube", 1, 1, 1, 1.5, 10, 200, 30))\nprint(vcol("Cube", 2, 0), vcol("Cube", 2, 1), vcol("Cube", 2, 2), vcol("Cube", 2, 3), vcol("Cube", 6, 1))\nprint(vcol("Cube", 0, 0), vcol("Cube", 7, 0), vcol("Cube", 7, 1), vcol("Cube", 7, 2), vcol("Cube", 7, 3), vcol("Cube", 8, 0), vcol("Cube", -1, 0), vcol("Cube", 0, 4), vcol("Cube", 0, -1))',
         'vcol: none yet, after vpaint, out of range')
    same(PRE + 'print(bake("S", "H", "normal", "T"), bake("S", "H", "ao", "T", 0.5), bake("S", "H", "curvature", "T"), bake("S", "H", "ao", "T", -1), bake("S", "S", "normal", "T"))',
         'bake: normal, ao, curvature into an 8-bit image')
    same(PRE + 'print(bake("Cube", "H", "normal", "T"), bake("H", "S", "ao", "U"))', 'bake: a low mesh without UVs (-1); into a small image')
    same(PRE + 'sculpt("S", "draw", 0, 0, 1, 0.2, 0, 1, 0.5, 0.5)\nsculpt("S", "draw", 0, 0, 1, 0.2, 0, 1, 0.5, -0.5)\nprint(verts("S"), volume("S"))', 'sculpt: draw, inverted')
    for b in ('clay strips', 'crease', 'inflate', 'grab', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer', 'mask'):
        same(PRE + f'sculpt("S", "{b}", -0.3, 0.1, 0.9, 0.3, 0.2, 0.95, 0.4, 0.8)\nsculpt("S", "draw", 0, 0, 1, 0.1, 0, 1, 0.5, 0.5)\nprint(volume("S"))', f'sculpt: {b}, then draw')
    for b in ('draw', 'smooth', 'grab', 'mask', 'layer', 'flatten'):
        same(PRE + f'sculpt("S", "{b}", 0, 0, 1, 0.2, 0, 1, 0.5, sqrt(-1))\nsculpt("S", "draw", 0, 0, 1, 0.1, 0, 1, 0.5, 0.5)\nprint(volume("S"))', f'sculpt: {b} with a NaN strength, then draw')
    same(PRE + 'layer("T", "add")\nprint(paint("S", sqrt(-1), 0, 0, 255))\nprint(paint("S", 0, 0, 1, sqrt(-1)))', 'paint into a layer with a NaN point')
    same(PRE + 'sculpt("S", "draw", "0", "1cm", "1m", "0.2", "0", "50cm*2", "0.5", "1/2")\nprint(volume("S"))', 'sculpt: the numbers as expressions (units)')
    same(PRE + 'sculpt("S", "draw", 0, 0, 1, 0.2, 0, 1, 0.5, 0.5)\nprint(seams("S", "sharp"), unwrap("S"))\nsculpt("Cube", "inflate", 1, 1, 1, 1, 1, 1, 1, 1)\nsculpt("S", "smooth", 0, 0, 1, 0, 0, 1, 1, 1)\nprint(volume("S"), volume("Cube"))',
         'sculpt on two objects in turn, UVs between')
    same(PRE + 'edit("S")\nsculpt("S", "draw", 0, 0, 1, 0.2, 0, 1, 0.5, 0.5)\nprint(volume("S"))', 'sculpt from edit mode')
    same(PRE + 'move("S", 1, 2, 3)\nscale("S", 2)\nprint(paint("S", 1, 2, 5, 1, 9, 9, 9), vpaint("S", 1, 2, 5, 1), bake("S", "H", "ao", "T"))\nsculpt("S", "draw", 1, 2, 5, 1, 2, 5, 1, 1)\nprint(volume("S"))',
         'a moved, scaled object: world points')

# ---- argument counts -----------------------------------------------------------------------

if want('counts'):
    print('-- each argument count --')
    for name, (lo, hi, args) in SPECS.items():
        for n in range(max(0, lo - 1), hi + 2):
            a = (args + ['1'] * 12)[:n]
            same(pre_for(name) + f'print({call(name, a)})', f'{name} with {n} argument(s)', save=lo <= n <= hi)

# ---- wrong types and bad names -------------------------------------------------------------

ALTS = ['3', '"zz"', '""', 'nil', '"Cube"', '"Light"', '"T"', '"2cm"', '"1+"', '"S"']

if want('types'):
    print('-- wrong types and bad names in each place --')
    for name, (lo, hi, args) in SPECS.items():
        for k in range(hi):
            for alt in ALTS:
                if alt == args[k]:
                    continue
                a = list(args)
                a[k] = alt
                same(pre_for(name) + f'print({call(name, a)})', f'{name}: argument {k + 1} = {alt}')

if want('types'):
    print('-- two bad arguments at once --')
    for name, (lo, hi, args) in SPECS.items():
        for i in range(hi):
            for j in range(i + 1, hi):
                a = list(args)
                a[i] = a[j] = '"zz"'
                same(pre_for(name) + f'print({call(name, a)})', f'{name}: arguments {i + 1} and {j + 1} bad')

# ---- edge values ---------------------------------------------------------------------------

EDGES = ['sqrt(-1)', '1e308 * 10', '-1e308 * 10', '1e300', '-5', '0', '2147483648', '-2147483649', '4294967297', '0.999999']

if want('edges'):
    print('-- edge values: NaN, infinities, huge, negative --')
    for name, (lo, hi, args) in SPECS.items():
        for k in range(hi):
            if not re.match(r'^-?[0-9.]+$', args[k]):
                continue
            for e in EDGES:
                a = list(args)
                a[k] = e
                same(pre_for(name) + f'print({call(name, a)})', f'{name}: argument {k + 1} = {e}')

# ---- random calls --------------------------------------------------------------------------

NUMS = ['0', '1', '-1', '0.5', '2', '0.25', '-0.3', '7', '31', '255', '300', '1.1', '0.9', 'sqrt(-1)']
WORDS = {'unwrap': ['"smart"', '"x"'], 'seams': ['"mark"', '"clear"', '"sharp"', '"none"', '"x"'],
         'uvstat': ['"islands"', '"angle"', '"area"', '"flipped"', '"overlap"', '"inside"'],
         'layer': ['"count"', '"add"', '"active"', '"opacity"', '"blend"', '"visible"', '"remove"', '"merge"'],
         'bake': ['"normal"', '"ao"', '"curvature"'],
         'sculpt': ['"draw"', '"clay strips"', '"crease"', '"inflate"', '"grab"', '"snake hook"', '"smooth"', '"flatten"', '"pinch"', '"layer"', '"mask"']}
MESHES = ['"S"', '"S"', '"Cube"', '"H"']


def rand_call(rng):
    name = rng.choice(list(SPECS))
    lo, hi, args = SPECS[name]
    n = rng.randint(lo, hi)
    out = []
    for k in range(n):
        v = args[k]
        if v in ('"S"', '"H"'):
            v = rng.choice(MESHES)
        elif v == '"T"':
            v = rng.choice(['"T"', '"U"'])
        elif v.startswith('"'):
            v = rng.choice(WORDS.get(name, [v]))
        else:
            v = rng.choice(NUMS) if rng.random() < 0.5 else v
        out.append(v)
    return call(name, out)


if want('random'):
    print(f'-- random calls (seed {SEED}) --')
    rng = random.Random(SEED)
    for r in range(RUNS):
        calls = [rand_call(rng) for _ in range(rng.randint(3, 10))]
        code = PRE + '\n'.join(f'print({c})' for c in calls)
        same(code, f'random {r}: ' + '; '.join(calls)[:150])

# ---- --run: the same through a file -------------------------------------------------------------

if want('run'):
    print('-- --run: a script file prints what --eval prints --')
    f = f'{T}/s.bees'
    for k, body in enumerate(['print(unwrap("Cube"), uvstat("Cube", "area"))\nprint(vpaint("Cube", 1, 1, 1, 1, 3, 4, 5), vcol("Cube", 7, 2))',
                              'print(seams("Cube", "sharp"))\nprint(sculpt("Cube", "nope", 0, 0, 0, 0, 0, 0, 1, 1))']):
        open(f, 'w').write(body + '\n')
        a, b = run(BIN, ['--eval', body]), run(BIN, ['--run', f])
        strip = lambda s: re.sub(r'running \S+', 'running', s)
        ok = not crashed(b) and a[0] == b[0] and strip(a[1]) == strip(b[1])
        check(ok, f'--run {k}' + ('' if ok else f': --eval {a[:2]!r} / --run {b[:2]!r}'))

# ---- undo / redo of a run (headless) -------------------------------------------------------------

def port_ops(*ops):
    a = []
    for o in ops:
        a += ['--op', o]
    return run(BIN, ['--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a])


def obj_state(path, name):
    """(mesh, UVs, colours) of an object, or None."""
    recs, _ = scene(path)
    for r in recs:
        if r[0][:32].rstrip(b'\0') == name.encode():
            return r[1:]
    return None


if want('undo'):
    print('-- undo / redo of a run with strokes: one step, everything back --')
    base = f'{T}/base.bee'
    b = run(BIN, ['--eval', PRE + f'op("file.save", "{base}")'])
    check(b[0] == 0 and os.path.exists(base), f'the scene to start from saved ({b[0]})')
    for k, body in enumerate([
            'sculpt("S", "draw", 0, 0, 1, 0.2, 0, 1, 0.5, 0.5)\nsculpt("S", "inflate", 0, 0, 1, 0.2, 0.1, 1, 0.5, 0.5)\nvpaint("S", 0, 0, 1, 0.6, 255, 0, 0)\nvpaint("S", 1, 0, 0, 0.6, 0, 0, 255)\nunwrap("S")\nmove("H", 3, 0, 0)',
            'vpaint("S", 0, 0, 1, 0.6, 255, 0, 0)\nsculpt("S", "grab", 0, 0, 1, 0.5, 0, 1, 0.5, 1)\nsculpt("S", "smooth", 0, 0, 1, 0.5, 0, 1, 0.5, 1)\nsculpt("S", "nope", 0, 0, 1, 0, 0, 1, 1, 1)',
            'add("sphere", "N", 2, 0, 0)\nsculpt("N", "draw", 2, 0, 1, 2, 0, 1, 0.5, 0.5)\nvpaint("N", 2, 0, 1, 0.5)\nuvmap("S", 2, 2, 0, 0)']):
        f = f'{T}/u{k}.bees'
        open(f, 'w').write(body + '\n')
        port_ops(f'file.open {base}', f'script.run {f}', f'file.save {T}/a.bee', 'edit.undo', f'file.save {T}/b.bee', 'edit.redo', f'file.save {T}/c.bee', 'edit.undo', 'edit.undo')
        log = open(f'{T}/log.txt').read() if os.path.exists(f'{T}/log.txt') else ''
        steps = re.findall(r'^(Undo|Redo): (.*)$', log, re.M)
        ok_files = all(os.path.exists(f'{T}/{x}.bee') for x in 'abc')
        check(ok_files, f'run {k}: the files saved')
        if not ok_files:
            continue
        check(steps[:3] == [('Undo', 'Script'), ('Redo', 'Script'), ('Undo', 'Script')] and 'Nothing to undo' in log, f'run {k}: one undo step, "Script" ({steps})')
        for nm in ('S', 'H', 'N'):
            s0, sa, sb, sc = obj_state(base, nm), obj_state(f'{T}/a.bee', nm), obj_state(f'{T}/b.bee', nm), obj_state(f'{T}/c.bee', nm)
            if sa is None and s0 is None:
                continue
            check(sb == s0, f'run {k}: {nm} undone: as before the run' + ('' if sb == s0 else f' ({[i for i in range(3) if (sb or (0, 0, 0))[i] != (s0 or (0, 0, 0))[i]]})'))
            check(sc == sa, f'run {k}: {nm} redone: as after the run')
        # (UIDS: the next object id stays where it got, so an id is never given twice)
        und = [x for x in scene_diff(base, f'{T}/b.bee') if x != 'UIDS']
        check(und == [], f'run {k}: the whole scene undone: {und[:3]}')
        check(scene_diff(f'{T}/a.bee', f'{T}/c.bee') == [], f'run {k}: the whole scene redone: {scene_diff(f"{T}/a.bee", f"{T}/c.bee")[:3]}')
        changed = scene_diff(base, f'{T}/a.bee')
        check(changed != [], f'run {k}: the run changed the scene ({changed[:3]})')
        for x in 'abc':
            os.unlink(f'{T}/{x}.bee')

# ---- garbage -----------------------------------------------------------------------------------------

if want('fuzz'):
    print(f'-- garbage calls: no crash, no hang (seed {SEED}) --')
    rng = random.Random(SEED ^ 0x5eed)
    junk = ['nil', '""', '"S"', '"T"', '"Cube"', '"Light"', '"draw"', '"smart"', '"mark"', '"add"', '"ao"', 'sqrt(-1)', '1e308 * 10', '-1e308 * 10', '1e300', '-1e300',
            '0', '-1', '1', '2147483647', '-2147483648', '4294967295', '1e-300', '"' + 'x' * 300 + '"', '"1/0"', '"2*"']
    bad = 0
    for r in range(RUNS * 4):
        lines = []
        for _ in range(rng.randint(1, 12)):
            name = rng.choice(list(SPECS))
            lo, hi, args = SPECS[name]
            n = rng.randint(lo, hi)
            a = [rng.choice(junk) if rng.random() < 0.4 else args[k] for k in range(n)]
            lines.append(f'print({call(name, a)})')
        code = PRE + '\n'.join(lines)
        rc, out, err = run(BIN, ['--eval', code], timeout=300)
        if rc not in (0, 1) or 'panic' in err or 'error: line' not in out and rc == 1:
            bad += 1
            print(f'  FAIL fuzz {r}: rc {rc} {err[-300:]!r}\n{code}')
    check(bad == 0, f'{RUNS * 4} garbage scripts: no crash, no hang ({bad} bad)')

shutil.rmtree(T, True)
for f in FAILS[:30]:
    print('  failed:', f.splitlines()[0])
print(f'bs_paint fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
