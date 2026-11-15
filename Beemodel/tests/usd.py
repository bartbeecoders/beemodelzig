#!/usr/bin/env python3
"""The OpenUSD import (usd.zig, usdc.zig, usda.zig, usdlayer.zig, usdmat.zig,
usdphys.zig, graphops.gltf) against OpenUSD (pxr).

  s_readers   every spec and field file.usd_dump writes of random layers and
              stages pxr makes (tests/usd_gen.py; crate files pxr writes and
              text files: every value type, inlined and compressed arrays,
              float tables, list ops, payloads, variants) and a small stage:
              each file read, the dump the same twice
  s_pxr       the same files as OpenUSD reads them (tests/usd_pxr.py, pxr's
              Sdf): every field the same, but where BeeModel reads otherwise
              (empty crate arrays and time code arrays: none; required fields
              at their fallback: not stored); a text file as the crate
              usdcat makes of it
  s_damage    damaged crate and text files (cut, bytes flipped, LZ4 garbage,
              huge counts, path trees that loop, deep nesting): no crash, no
              hang, the same answer twice, imported cleanly; no leak
  s_gen       a small stage (a sublayer, a reference, a variant, a material
              bound, an inactive prim and a guide) and random stages
              (usd_gen.py, .usda and their .usdc) imported: the .bee reads
              back with finite vertices, opened and saved again the same
  s_stage     each stage's meshes (faces, world bounds) as OpenUSD (pxr)
              composes them; rotateX / Z and the three-axis orders
  s_edges     hand-made edge cases: UVs of exactly 0, 0, polygons of 2 and of
              1025 corners, bad indices, negative counts, subsets out of
              range, shear (baked), reset transform stacks, Z up in
              centimetres, nested bodies, drives, mimic joints, limits at
              infinity, disabled joints: imported cleanly, read back
  s_tex       textures capped (file.usd_texture_size): the <name>.<size>.png
              copies made once, at most that size, the scene loads them
  s_undo      an import undone and redone; undo after edit mode
  s_window    a .usda dropped (--drop); File > Import > Import USD... offers
              the file browser
  s_cycles    sublayer and reference cycles, a missing file: no hang

    python3 tests/usd.py BIN [damage-runs=200] [seed]

USD_ONLY=s_a,s_b runs only those. pxr runs with LD_PRELOAD=libjemalloc (its
static TLS); without pxr the pxr checks say so and count as failed.
"""
import json, math, os, random, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 200
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
FAILS = []
T = tempfile.mkdtemp(prefix='beeusd-', dir=os.environ.get('BEEUSD_TMP', '/tmp'))
ENV = dict(os.environ)
PXENV = dict(os.environ, LD_PRELOAD='/usr/lib/libjemalloc.so.2') if os.path.exists('/usr/lib/libjemalloc.so.2') else dict(os.environ)
GEN = os.path.join(T, 'gen')
NGEN = int(os.environ.get('USD_GEN', '24'))
STAGE = os.path.join(T, 'stage', 'root.usda')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def run(b, code, timeout=300):
    """--eval: (returncode, stdout); returncode -9 when it ran out of time."""
    try:
        r = subprocess.run([b, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return -9, ''


def port(*a, log=None):
    lg = log or os.path.join(T, 'log.txt')
    r = subprocess.run([BIN, '--shot', os.path.join(T, 'u.ppm'), '--dump-log', lg, '--dump-ui', os.path.join(T, 'u.txt'), *a],
                       capture_output=True, text=True, timeout=600, env=ENV)
    return r, (open(lg, errors='replace').read() if os.path.exists(lg) else '')


def q(p):
    return p.replace('\\', '\\\\').replace('"', '\\"')


def dumps(b, files, timeout=600):
    """b's file.usd_dump of each file: {file: text or None}, and the return code."""
    out = os.path.join(T, 'dumps-%d' % random.randrange(1 << 30))
    os.makedirs(out)
    code = '\n'.join('op("file.usd_dump", "%s %s/%d.txt")' % (q(f), out, k) for k, f in enumerate(files))
    rc, _ = run(b, code, timeout)
    d = {}
    for k, f in enumerate(files):
        p = os.path.join(out, '%d.txt' % k)
        d[f] = open(p, 'rb').read() if os.path.exists(p) else None
    shutil.rmtree(out, True)
    return d, rc


def parse(text):
    d = {}
    for line in (text or b'').decode(errors='replace').splitlines():
        f = line.split('\t', 2)
        if len(f) == 3:
            d[(f[0], f[1])] = f[2]
    return d


def gen(d=GEN, axis=False):
    """The random files (pxr), made once (without rotateX / Y / Z ops and the
    three-axis orders but XYZ unless asked)."""
    if os.path.isdir(d):
        return True
    os.makedirs(d)
    e = dict(PXENV)
    if not axis:
        e['USDGEN_NOAXIS'] = '1'
    r = subprocess.run([sys.executable, os.path.join(HERE, 'usd_gen.py'), d, str(SEED % 100000), str(NGEN)],
                       capture_output=True, text=True, env=e)
    if r.returncode != 0:
        print(r.stderr[-800:])
    return r.returncode == 0


def genfiles(kind, d=GEN):
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(kind) and not f.endswith('_ref.usda'))


def stage():
    """A small stage: a sublayer, a reference to another file, a variant, a
    material bound, an inactive prim and a guide (left out): 4 meshes come in."""
    d = os.path.dirname(STAGE)
    if os.path.exists(STAGE):
        return STAGE
    os.makedirs(d)
    tri = '\n    int[] faceVertexCounts = [3, 3]\n    int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]\n    point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]\n'
    open(os.path.join(d, 'parts.usda'), 'w').write('#usda 1.0\n(\n    defaultPrim = "Leg"\n)\ndef Mesh "Leg"\n{%s    double3 xformOp:translate = (0, -1, 0)\n'
                                                   '    uniform token[] xformOpOrder = ["xformOp:translate"]\n}\n' % tri)
    open(os.path.join(d, 'over.usda'), 'w').write('#usda 1.0\nover "World"\n{\n    def Mesh "Extra"\n    {%s    }\n}\n' % tri)
    open(STAGE, 'w').write("""#usda 1.0
(
    defaultPrim = "World"
    subLayers = [@./over.usda@]
    metersPerUnit = 1
    upAxis = "Y"
)
def Xform "World" {
    def Mesh "Top" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    ) {
        %s
        double3 xformOp:translate = (0, 2, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
        rel material:binding = </World/Looks/Paint>
    }
    def "L" (
        prepend references = @./parts.usda@
    )
    {
        double3 xformOp:translate = (3, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Xform "V" (
        variants = {
            string look = "b"
        }
        prepend variantSets = "look"
    )
    {
        variantSet "look" = {
            "a" {
                def Mesh "VA"
                {%s}
            }
            "b" {
                def Mesh "VB"
                {%s}
            }
        }
    }
    def Mesh "Gone" (
        active = false
    )
    {%s}
    def Mesh "Helper"
    {
        uniform token purpose = "guide"%s}
    def Scope "Looks" {
        def Material "Paint" {
            token outputs:surface.connect = </World/Looks/Paint/S.outputs:surface>
            def Shader "S" {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.8, 0.1, 0.1)
                float inputs:metallic = 1
                float inputs:roughness = 0.25
                token outputs:surface
            }
        }
    }
}
""" % (tri, tri, tri, tri, tri))
    return STAGE


# ---- the readers ---------------------------------------------------------------------

def s_readers():
    print('-- the readers: file.usd_dump --', flush=True)
    if not gen():
        check(False, 'usd_gen.py made the random files (pxr)')
        return
    files = genfiles('.usda') + genfiles('.usdc') + sorted(os.path.join(GEN, f) for f in os.listdir(GEN) if f.endswith('_ref.usda'))
    stage()
    files += [STAGE, os.path.join(os.path.dirname(STAGE), 'parts.usda')]
    p, rc = dumps(BIN, files)
    p2, rc2 = dumps(BIN, files)
    got = [f for f in files if p[f]]
    nf = sum(len(parse(p[f])) for f in got)
    check(rc == 0 and rc2 == 0 and len(got) == len(files) and nf > 2000, '%d files (crate and text) read: %d fields (%d not read)' % (len(files), nf, len(files) - len(got)))
    check(p == p2, 'read again: the same dump, byte for byte')
    t = [parse(p[f]) for f in files if os.path.basename(f).startswith('types') and f.endswith('.usdc')]
    check(t and any(v.startswith('v 4') for k, v in t[0].items() if k[1] == 'default'), 'quaternions read (a types .usdc): %d fields' % (len(t[0]) if t else 0))


def same_field(g, w):
    if g == w:
        return True
    if w == 'LIST0':                    # an empty list: any empty kind
        return g is not None and g.split(' ')[1:2] == ['0']
    if g and w and g[0] == w[0] == 'f':  # float sums: rounding of the last digit
        a, b = g.split(), w.split()
        return a[:3] == b[:3] and all(abs(int(x) - int(y)) <= 2 + abs(int(y)) * 1e-6 for x, y in zip(a[3:], b[3:]))
    return False


def pxr_dumps(files):
    r = subprocess.run([sys.executable, os.path.join(HERE, 'usd_pxr.py')] + files, capture_output=True, text=True, env=PXENV)
    out, cur = {}, None
    for line in r.stdout.splitlines():
        if line.startswith('== '):
            cur = line[3:]
            out[cur] = {}
        elif cur is not None and line.count('\t') >= 2:
            p, k, v = line.split('\t', 2)
            out[cur][(p, k)] = v
    return out


def s_pxr():
    print('-- the readers against OpenUSD (pxr) --', flush=True)
    if not gen():
        check(False, 'usd_gen.py made the random files (pxr)')
        return
    files = genfiles('.usda') + genfiles('.usdc')
    ref = pxr_dumps(files)
    check(len(ref) == len(files), 'pxr read %d of %d files' % (len(ref), len(files)))
    p, _ = dumps(BIN, files)
    tot = odd = 0
    worst = []
    for f in files:
        w, g = ref.get(f, {}), parse(p[f])
        for k, v in w.items():
            tot += 1
            gv = g.get(k)
            if same_field(gv, v):
                continue
            if gv is None and (k[1] in ('variability', 'custom') and v == 'i 0' or k[1] == 'specifier' and v == 'i 1'):
                odd += 1                    # (a required field at its fallback: not in the file)
                continue
            if gv == 'none' and f.endswith('.usdc') and (v == 'LIST0' or (k[0].endswith('.a9') or k[0].endswith('.s9'))):
                odd += 1                    # (BeeModel's reading: an empty crate array, time codes)
                continue
            if gv is None and f.endswith('.usda') and k[1] in ('customLayerData', 'subLayerOffsets', 'customData', 'assetInfo'):
                odd += 1                    # (dictionaries: a text file's are read past)
                continue
            tn = g.get((k[0], 'typeName'), '')
            if f.endswith('.usda') and gv and v and gv[:1] == v[:1] == 'f' and (tn.startswith('s half') or tn.endswith('h[]')):
                odd += 1                    # (a text file's half arrays: read at float precision)
                continue
            worst.append((os.path.basename(f), k, gv, v))
        extra = [k for k in g if k not in w and k[1] not in ('properties', 'primChildren', 'variantSetChildren', 'variantChildren')]
        worst += [(os.path.basename(f), k, g[k], '-') for k in extra]
    for x in worst[:6]:
        print('       %s %s\n         got  %s\n         pxr  %s' % (x[0], x[1], (x[2] or '-')[:100], (x[3] or '-')[:100]))
    check(tot > 2000 and not worst, '%d fields as OpenUSD reads them (%d differ; %d where BeeModel reads otherwise: empty crate arrays and'
          ' time code arrays none, required fields at their fallback not stored, text files\' dictionaries read past and half arrays'
          ' at float precision)' % (tot, len(worst), odd))
    # a text file as the crate usdcat makes of it
    IGN = {'customLayerData', 'subLayerOffsets', 'assetInfo', 'customData', 'displayGroup', 'displayName'}
    pairs = []
    for f in genfiles('.usda')[:8]:
        c = f[:-1] + 'c.cat.usdc'
        if subprocess.run(['usdcat', f, '-o', c], capture_output=True, env=PXENV).returncode == 0:
            pairs.append((f, c))
    d, _ = dumps(BIN, [x for pr in pairs for x in pr])
    bad, nk = [], 0
    for a, c in pairs:
        A, C = parse(d[a]), parse(d[c])
        keys = [k for k in C if k[1] not in IGN and '[' not in k[0]]
        nk += len(keys)
        bad += [(os.path.basename(a), k, A.get(k), C[k]) for k in keys if A.get(k) != C[k] and not (k[1] == 'documentation')]
    for x in bad[:4]:
        print('       %s %s\n         text  %s\n         crate %s' % (x[0], x[1], (x[2] or '-')[:90], x[3][:90]))
    check(len(pairs) > 3 and not bad, '%d text files read as the crates usdcat makes of them: %d fields (%d differ)' % (len(pairs), nk, len(bad)))


# ---- damaged files ---------------------------------------------------------------------

def damaged(rng, data, text):
    b = bytearray(data)
    k = rng.randrange(6)
    if k == 0:
        return bytes(b[:rng.randrange(len(b))])
    if k == 1 or text:
        for _ in range(rng.randint(1, 8)):
            at = rng.randrange(len(b))
            if text and rng.random() < .5:
                b[at:at + rng.randint(1, 30)] = b''
            elif at < len(b):
                b[at] = rng.choice(b'(){}[]<>@"=,#\n.-0') if text else rng.randrange(256)
        return bytes(b)
    if k == 2:                          # a count or offset made huge
        at = rng.randrange(16, len(b) - 8) & ~7
        b[at:at + 8] = struct.pack('<Q', rng.choice([1 << 62, 0x7fffffff, 0x10000001, 0xffffffffffffffff, len(b) * 3]))
        return bytes(b)
    if k == 3:                          # LZ4 garbage in a section
        at = rng.randrange(88, len(b))
        for j in range(rng.randint(4, 64)):
            if at + j < len(b):
                b[at + j] = rng.randrange(256)
        return bytes(b)
    if k == 4:                          # a byte here and there
        for _ in range(4):
            b[rng.randrange(88, len(b))] ^= 1 << rng.randrange(8)
        return bytes(b)
    at = rng.randrange(88, len(b) - 4) & ~3  # an int32 of a run negative
    b[at:at + 4] = struct.pack('<i', rng.choice([-1, -2, -5, 1 << 30, 7]))
    return bytes(b)


def s_damage():
    print('-- damaged files --', flush=True)
    rng = random.Random(SEED)
    srcs = [stage(), os.path.join(os.path.dirname(STAGE), 'parts.usda')]
    if gen():
        srcs += [f for f in genfiles('.usdc') + genfiles('.usda') if os.path.basename(f).startswith('types')][:2] + genfiles('.usdc')[:4] + genfiles('.usda')[:4]
    d = os.path.join(T, 'dmg')
    os.makedirs(d, exist_ok=True)
    files = []
    for k in range(RUNS):
        s = srcs[k % len(srcs)]
        data = open(s, 'rb').read()
        f = os.path.join(d, 'd%d%s' % (k, os.path.splitext(s)[1]))
        open(f, 'wb').write(damaged(rng, data, s.endswith('.usda')))
        files.append(f)
    t0 = time.time()
    p, rc = dumps(BIN, files, timeout=900)
    tp = time.time() - t0
    nread = sum(1 for f in files if p[f] is not None)
    check(rc == 0 and nread > 0, '%d damaged files read: no crash, no hang (rc %d, %.1f s; %d read, the rest refused)' % (len(files), rc, tp, nread))
    p2, rc2 = dumps(BIN, files, timeout=900)
    check(rc2 == 0 and p2 == p, 'read again: the same dumps, the same refused')
    # imported too: no crash, every .bee saved reads back
    out = os.path.join(T, 'dimp')
    os.makedirs(out, exist_ok=True)
    code = '\n'.join('n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\nop("file.save", "%s/%d.bee")' % (q(f), out, k) for k, f in enumerate(files))
    rc, _ = run(BIN, code, 1800)
    saved = [os.path.join(out, x) for x in os.listdir(out)]
    bad = [x for x in saved if not reads_back(x, finite=False)]
    check(rc == 0 and len(saved) == len(files) and not bad, '%d damaged files imported: no crash, every .bee read back (%d saved, %s)' % (len(files), len(saved), bad[:2]))
    # made to hurt: huge counts, deep nesting
    for name, body in (('a million "("', 'def "A" { float3 x = ' + '(' * 1000000 + '}'),
                       ('100000 nested prims', 'def "A" {' * 100000),
                       ('a million list items', 'def "A" { int[] x = [' + '1,' * 1000000 + '] }'),
                       ('a string to the end', 'def "A" { string s = "' + 'x' * 100000)):
        f = os.path.join(d, 'deep.usda')
        open(f, 'w').write('#usda 1.0\n' + body + '\n')
        t0 = time.time()
        g, rc = dumps(BIN, [f], timeout=120)
        check(rc == 0 and time.time() - t0 < 60, '%s: no crash, no hang (%s, %.1f s)' % (name, 'read' if g[f] else 'refused', time.time() - t0))
    # no leak: the readers and a stage's composition again and again, the memory flat
    nm = os.path.join(d, 'nomesh.usda')
    rf = os.path.join(d, 'nmref.usda')         # (no meshes: nothing made, the scene stays as it is)
    open(rf, 'w').write('#usda 1.0\n( defaultPrim = "R" )\ndef Xform "R" ( variants = { string v = "a" } prepend variantSets = "v" ) {\n'
                        ' double3 xformOp:translate = (1, 2, 3)\n uniform token[] xformOpOrder = ["xformOp:translate"]\n'
                        ' variantSet "v" = { "a" { def Xform "VA" { float[] f = [1, 2, 3] } } }\n def Xform "K" { int[] x = [1, 2] }\n}\n')
    open(nm, 'w').write('#usda 1.0\n( subLayers = [@%s@] )\ndef Xform "A" ( prepend references = @%s@ ) { def "B" ( prepend payload = @%s@ ) {} }\n'
                        % (rf, rf, rf))
    three = (srcs * 3)[2:5] if len(srcs) >= 5 else [STAGE] * 3

    def rss(n):
        code = ('for i in 0..%d { op("file.usd_dump", "%s %s/lk.txt")\nop("file.usd_dump", "%s %s/lk.txt")\n'
                'op("file.usd_dump", "%s %s/lk.txt")\nop("file.import_usd", "%s") }' % (n, three[0], d, three[1], d, three[2], d, nm))
        pr = subprocess.Popen([BIN, '--eval', code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=ENV)
        _, st, ru = os.wait4(pr.pid, 0)
        return ru.ru_maxrss, st
    r1, s1 = rss(20)
    r2, s2 = rss(400)
    check(s1 == 0 and s2 == 0 and r2 - r1 < 8000, 'no leak: 400 rounds of three files read and a stage composed take %d KB more than 20 (%d KB)' % (r2 - r1, r2))
    # PATHS jumps that send the walk back: 2^n visits; refused
    mk = os.path.join(d, 'jumps.usdc')
    open(mk, 'wb').write(crate_with_jumps(60))
    t0 = time.time()
    g, rc = dumps(BIN, [mk], timeout=60)
    check(rc == 0 and g[mk] is None and time.time() - t0 < 30, 'a path tree whose jumps loop back: refused as damaged in %.1f s' % (time.time() - t0))


def crate_with_jumps(n):
    """A small crate file whose PATHS section has n paths each jumping to the
    next as a sibling and having it as a child: every node visited 2^k times."""
    def lz4(raw):
        # one literal run
        out = bytearray()
        ln = len(raw)
        if ln >= 15:
            out.append(0xf0)
            ln -= 15
            while ln >= 255:
                out.append(255)
                ln -= 255
            out.append(ln)
        else:
            out.append(ln << 4)
        return bytes(out) + raw
    def fast(raw):
        return b'\0' + lz4(raw)
    def ints(vals):
        n = len(vals)
        codes = bytearray((n * 2 + 7) // 8)
        data = b''
        prev = 0
        for i, v in enumerate(vals):
            codes[i // 4] |= 3 << ((i % 4) * 2)
            data += struct.pack('<i', v - prev)
            prev = v
        raw = struct.pack('<i', 0) + bytes(codes) + data
        c = fast(raw)
        return struct.pack('<Q', len(c)) + c
    toks = b'A\0'
    secs = []
    body = b''
    def sec(name, d):
        nonlocal body
        secs.append((name, 88 + len(body), len(d)))
        body += d
    c = fast(toks)
    sec(b'TOKENS', struct.pack('<QQQ', 1, len(toks), len(c)) + c)
    sec(b'STRINGS', struct.pack('<Q', 0))
    c = fast(b'')
    sec(b'FIELDS', struct.pack('<Q', 0) + ints([]) + struct.pack('<Q', 1) + b'\0')
    sec(b'FIELDSETS', struct.pack('<Q', 0) + ints([]))
    sec(b'PATHS', struct.pack('<QQ', n, n) + ints(list(range(n))) + ints([0] * n) + ints([1] * (n - 1) + [-2]))
    sec(b'SPECS', struct.pack('<Q', 0) + ints([]) + ints([]) + ints([]))
    toc = struct.pack('<Q', len(secs)) + b''.join(nm.ljust(16, b'\0') + struct.pack('<QQ', st, sz) for nm, st, sz in secs)
    head = b'PXR-USDC' + bytes([0, 8, 0]) + b'\0' * 5 + struct.pack('<Q', 88 + len(body)) + b'\0' * 64
    return head + body + toc


# ---- imports ------------------------------------------------------------------------------

IGNORE = {b'WSPC'}      # (the workspaces)


def chunks(path):
    d = {}
    for t, c in beefile.chunks(path):
        d.setdefault(t, []).append(c)
    return d


def bee_after(b, code_before, path, extra='', tag='x'):
    out = os.path.join(T, '%s-%d.bee' % (tag, random.randrange(1 << 30)))
    code = 'n = count()\nfor i in 0..n { delete(name(0)) }\n%s\nop("file.import_usd", "%s")\n%s\nop("file.save", "%s")' % (code_before, q(path), extra, out)
    rc, so = run(b, code)
    return (out if os.path.exists(out) else None), rc, so


def png_pixels(data):
    from PIL import Image
    import io
    return Image.open(io.BytesIO(data)).convert('RGBA').tobytes()


def imgd(c):
    """IMGD: per embedded image (index, decoded pixels)."""
    out, o = [], 0
    while o + 8 <= len(c):
        ix, n = struct.unpack_from('<II', c, o)
        out.append((ix, png_pixels(c[o + 8:o + 8 + n])))
        o += 8 + n
    return out


def compare_bee(a, b):
    """The chunks that differ (two icon meshes at the end, an empty ANIM left
    out, the embedded images' PNG bytes compared as pixels)."""
    A, B = chunks(a), chunks(b)
    bad = []
    for t in sorted(set(A) | set(B)):
        if t in IGNORE:
            continue
        x, y = A.get(t, []), B.get(t, [])
        if t == b'MESH':
            if x != y[:len(x)] or len(y) - len(x) not in (0, 2):
                bad.append('MESH %d %d' % (len(x), len(y)))
            continue
        if t == b'ANIM' and x == [b''] and y == []:
            continue
        if t == b'IMGD':
            if [imgd(c) for c in x] != [imgd(c) for c in y]:
                bad.append('IMGD pixels')
            continue
        if x != y:
            bad.append('%s %s %s' % (t.decode(), [len(c) for c in x], [len(c) for c in y]))
    return bad


def reads_back(path, finite=True):
    """The .bee reads back: objects, meshes with indices in range and (finite)
    finite vertices and places."""
    try:
        ob = beefile.objects(path)
        ms = beefile.meshes(path)
    except Exception:
        return False
    return all((not finite or all(math.isfinite(c) for v in vs for c in v)) and all(0 <= i < len(vs) for p in ps for i in p) for vs, ps in ms) \
        and (not finite or all(math.isfinite(x) for o in ob for x in o['loc'] + o['rot'] + o['scl']))


def import_ok(path, before='', extra=''):
    """Imported, saved, read back; opened and saved again: (what is wrong, objects)."""
    a, rc, _ = bee_after(BIN, before, path, extra, 'p')
    if not a:
        return ['no file (rc %d)' % rc], 0
    bad = [] if reads_back(a) else ['not finite or out of range']
    b = os.path.join(T, 're-%d.bee' % random.randrange(1 << 30))
    run(BIN, 'op("file.open", "%s")\nop("file.save", "%s")' % (q(a), q(b)))
    bad += compare_bee(a, b) if os.path.exists(b) else ['not saved again']
    n = len(beefile.objects(a))
    return bad, n


def objbounds(obj):
    got, g = {}, None
    if os.path.exists(obj):
        for line in open(obj):
            if line.startswith('o '):
                g = got.setdefault(line.split()[1].split('.')[0], [0, [1e30] * 3, [-1e30] * 3])
            elif line.startswith('v ') and g:
                w = list(map(float, line.split()[1:4]))
                for i in range(3):
                    g[1][i] = min(g[1][i], w[i])
                    g[2][i] = max(g[2][i], w[i])
            elif line.startswith('f ') and g:
                g[0] += 1
    return got


def s_gen():
    print('-- imports: a small stage, random stages --', flush=True)
    bad, n = import_ok(stage())
    check(not bad and n > 0, 'the small stage: %d objects, read back, saved again the same (%s)' % (n, bad[:3]))
    obj = os.path.join(T, 'x.obj')
    rc, out = run(BIN, 'n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\nop("file.export_obj", "%s")\n'
                       'for i in 0..count() { print("OB", name(i)) }\nprint("M", matof("Top"))\n'
                       'print("P", matget("Paint", "base", 0), matget("Paint", "metallic"), matget("Paint", "roughness"))' % (STAGE, obj))
    names = sorted(ln.split()[1] for ln in out.splitlines() if ln.startswith('OB '))
    check(names == ['Extra', 'L', 'Top', 'VB'], 'the meshes: the sublayer\'s, the reference\'s, the variant chosen; inactive and guide left out (%s)' % names)
    m = next((ln.split()[1:] for ln in out.splitlines() if ln.startswith('M ')), [])
    pp = [float(x) for x in next((ln.split()[1:] for ln in out.splitlines() if ln.startswith('P ')), [])]
    check(m == ['Paint'] and len(pp) == 3 and all(abs(a - b) < 1e-4 for a, b in zip(pp, [0.8, 1, 0.25])), 'its material bound: colour, metallic, roughness (%s %s)' % (m, pp))
    if not gen():
        check(False, 'usd_gen.py made the random files (pxr)')
        return
    bad, n, k = [], 0, 0
    for f in genfiles('.usda') + genfiles('.usdc'):
        if os.path.basename(f).startswith('types'):
            continue
        b, m = import_ok(f)
        k += 1
        n += m
        if b:
            bad.append((os.path.basename(f), b[:3]))
    for x in bad[:4]:
        print('       %s: %s' % x)
    check(k >= 6 and not bad and n > k, '%d random stages (text and crate): %d objects, each .bee read back, saved again the same (%d not)' % (k, n, len(bad)))


STAGE_REF = r"""
import json, sys
from pxr import Usd, UsdGeom
st = Usd.Stage.Open(sys.argv[1])
out = {}
up = UsdGeom.GetStageUpAxis(st)
mpu = UsdGeom.GetStageMetersPerUnit(st)
for p in st.Traverse(Usd.TraverseInstanceProxies()):
    im = UsdGeom.Imageable(p)
    if not p.IsA(UsdGeom.Mesh) or im.ComputePurpose() not in ('default', 'render') or im.ComputeVisibility() == 'invisible':
        continue
    m = UsdGeom.Mesh(p)
    cnt = m.GetFaceVertexCountsAttr().Get() or []
    pts = m.GetPointsAttr().Get() or []
    x = UsdGeom.Xformable(p).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    w = [x.Transform(q) for q in pts]
    if up == 'Z':
        w = [(v[0], v[2], -v[1]) for v in w]
    lo = [min(v[i] for v in w) * mpu for i in range(3)] if w else [0, 0, 0]
    hi = [max(v[i] for v in w) * mpu for i in range(3)] if w else [0, 0, 0]
    n = sum(1 for c in cnt if c >= 3)
    o = out.get(p.GetName())        # (prims of one name: one entry, as the objects' names merge)
    if o:
        n, lo, hi = o[0] + n, [min(a, b) for a, b in zip(o[1], lo)], [max(a, b) for a, b in zip(o[2], hi)]
    out[p.GetName()] = [n, lo, hi]
json.dump(out, sys.stdout)
"""


def stage_ref(f):
    """Each mesh's faces (3 corners or more) and world bounds as OpenUSD composes the stage."""
    sc = os.path.join(T, 'stage_ref.py')
    open(sc, 'w').write(STAGE_REF)
    r = subprocess.run([sys.executable, sc, f], capture_output=True, text=True, env=PXENV)
    return json.loads(r.stdout) if r.returncode == 0 else None


def s_stage():
    print('-- stages as OpenUSD composes them --', flush=True)
    gx = os.path.join(T, 'genx')
    if not gen(gx, axis=True):
        check(False, 'usd_gen.py made the random files (pxr)')
        return
    roots = [stage()] + [f for f in genfiles('.usda', gx) if os.path.basename(f).startswith('s')][:16]
    bad, n = [], 0
    for f in roots:
        want = stage_ref(f)
        if want is None:
            bad.append((os.path.basename(f), 'pxr'))
            continue
        obj = os.path.join(T, 'st.obj')
        if os.path.exists(obj):
            os.remove(obj)
        run(BIN, 'n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\nop("file.export_obj", "%s")' % (q(f), obj))
        got = objbounds(obj)
        for k in want:
            n += 1
            if want[k][0] == 0:
                continue            # (no polygon of 3 corners: no object)
            g = got.get(k[:26].split('.')[0]) or got.get(k)
            if g is None or g[0] != want[k][0] or any(abs(a - b) > 1e-3 * max(1, abs(b)) for a, b in zip(g[1] + g[2], want[k][1] + want[k][2])):
                bad.append((os.path.basename(f), k, g, want[k]))
    for x in bad[:4]:
        print('       %s' % (x,))
    check(n > 10 and not bad, '%d stages, %d meshes: faces and world bounds as OpenUSD composes them (%d differ)' % (len(roots), n, len(bad)))
    # rotateX / Z and the three-axis orders
    rot = os.path.join(T, 'rot.usda')
    tri = 'int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 2]\n point3f[] points = [(0,0,0), (1,0,0), (1,2,3)]'
    open(rot, 'w').write('#usda 1.0\n( metersPerUnit = 1 )\n'
                         'def Mesh "RX" { %s\n float xformOp:rotateX = 30\n uniform token[] xformOpOrder = ["xformOp:rotateX"]\n}\n'
                         'def Mesh "RZ" { %s\n double xformOp:rotateZ:a = -50\n uniform token[] xformOpOrder = ["xformOp:rotateZ:a"]\n}\n'
                         'def Mesh "ZYX" { %s\n float3 xformOp:rotateZYX = (10, 20, 30)\n uniform token[] xformOpOrder = ["xformOp:rotateZYX"]\n}\n'
                         'def Mesh "YXZ" { %s\n float3 xformOp:rotateYXZ = (-40, 20, 70)\n double3 xformOp:translate = (1, 2, 3)\n'
                         ' uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateYXZ"]\n}\n' % (tri, tri, tri, tri))
    want = stage_ref(rot) or {}
    obj = os.path.join(T, 'rot.obj')
    run(BIN, 'n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\nop("file.export_obj", "%s")' % (rot, obj))
    g = objbounds(obj)
    res = [k for k in want if not (k in g and all(abs(a - c) < 1e-4 for a, c in zip(g[k][1] + g[k][2], want[k][1] + want[k][2])))]
    check(len(want) == 4 and not res, 'rotateX / Z and the orders but XYZ: as OpenUSD turns them (%s differ)' % res)


# ---- edge cases -----------------------------------------------------------------------------

EDGES = {
    'uvzero.usda': '''#usda 1.0
def Mesh "M" {
    int[] faceVertexCounts = [3, 3]
    int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]
    point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]
    texCoord2f[] primvars:st = [(0,0), (1,0), (1,1), (0,1)] ( interpolation = "vertex" )
}
def Mesh "N" {
    int[] faceVertexCounts = [3, 3]
    int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]
    point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]
    texCoord2f[] primvars:st = [(0.5,0.5), (1,0), (1,1), (0,1)] ( interpolation = "vertex" )
    texCoord2f[] primvars:uv = [(0,0)] ( interpolation = "faceVarying" )
}
def Mesh "F" {
    int[] faceVertexCounts = [4]
    int[] faceVertexIndices = [0, 1, 2, 3]
    point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]
    texCoord2f[] primvars:st = [(0.25,0.5), (1,0.5)] ( interpolation = "faceVarying" )
    int[] primvars:st:indices = [0, 1, 1, 7]
}''',
    'polys.usda': '''#usda 1.0
( upAxis = "Z" metersPerUnit = 0.01 )
def Xform "R" ( kind = "component" ) {
    double3 xformOp:translate = (100, 0, 0)
    float3 xformOp:scale = (1, 2, 3)
    double3 xformOp:rotateXYZ = (10, 20, 30)
    uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"]
    def Mesh "Two" {
        int[] faceVertexCounts = [2, 3, 1025]
        int[] faceVertexIndices = [0, 1, 0, 1, 2, %s]
        point3f[] points = [%s]
        uniform token orientation = "leftHanded"
    }
    def Mesh "Bad" {
        int[] faceVertexCounts = [3, -1]
        int[] faceVertexIndices = [0, 1, 2, 0]
        point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
    }
    def Mesh "Far" {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 9]
        point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
    }
    def Mesh "Short" {
        int[] faceVertexCounts = [3, 3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
    }
    def Xform "Sheared" {
        matrix4d xformOp:transform = ( (1, 0.5, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (1, 2, 3, 1) )
        uniform token[] xformOpOrder = ["!resetXformStack!", "xformOp:transform"]
        def Mesh "S" {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
            quatf xformOp:orient = (0.7071068, 0, 0.7071068, 0)
            double3 xformOp:translate:pivot = (1, 1, 0)
            uniform token[] xformOpOrder = ["xformOp:translate:pivot", "xformOp:orient", "!invert!xformOp:translate:pivot"]
        }
    }
    def Mesh "Subs" {
        int[] faceVertexCounts = [3, 3, 3]
        int[] faceVertexIndices = [0, 1, 2, 0, 2, 3, 1, 2, 3]
        point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]
        rel material:binding = </R/Looks/A>
        def GeomSubset "S1" ( prepend apiSchemas = ["MaterialBindingAPI"] ) {
            uniform token elementType = "face"
            uniform token familyName = "materialBind"
            int[] indices = [1, 7, -3]
            rel material:binding = </R/Looks/B>
        }
        def GeomSubset "S2" {
            uniform token familyName = "materialBind"
            int[] indices = [2]
            rel material:binding = </R/Looks/A>
        }
        def GeomSubset "S4" {
            uniform token elementType = "point"
            int[] indices = [0]
            rel material:binding = </R/Looks/B>
        }
        def GeomSubset "S3" {
            uniform token familyName = "other"
            int[] indices = [0]
            rel material:binding = </R/Looks/B>
        }
    }
    def Scope "Looks" {
        def Material "A" {
            token outputs:surface.connect = </R/Looks/A/S.outputs:surface>
            def Shader "S" {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (1.5, -1, nan)
                float inputs:ior = inf
                float inputs:opacity = nan
                float inputs:roughness = -3
                color3f inputs:emissiveColor = (0.5, 0.5, 0.5)
            }
        }
        def Material "B" {
            token outputs:surface.connect = </R/Looks/B/S.outputs:surface>
            def Shader "S" {
                uniform token info:id = "UsdPreviewSurface"
                float inputs:opacityThreshold = 0.5
                color3f inputs:diffuseColor.connect = </R/Looks/B/T.outputs:rgb>
                float inputs:metallic.connect = </R/Looks/B/T.outputs:b>
                float inputs:roughness = 0.75
                color3f inputs:emissiveColor.connect = </R/Looks/B/T.outputs:rgb>
            }
            def Shader "T" {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @./tex.png@
            }
        }
    }
}''',
    'lists.usda': '''#usda 1.0
( subLayers = [@./nope.usda@ (offset = 2), @./polys.usda@] defaultPrim = "/A" )
def Xform "A" (
    prepend references = @./polys.usda@</R/Looks>
    append references = [@./polys.usda@</R/Subs>, </B>]
    delete references = @./x.usda@
    prepend apiSchemas = ["One"]
    append apiSchemas = ["Two"]
    variants = { string look = "b" string a = "z" }
    prepend variantSets = ["look"]
    doc = "a\\tb"
    "lone doc"
    kind = "component"
    instanceable = true
) {
    rel r = [</A/x>, </B>]
    delete rel d = </A>
    custom uniform float u = 1.5 ( customData = { int x = 1 } )
    double t.timeSamples = { 0: 1, 1: 2 }
    float c.connect = </B.outputs:x>
    quatf q = (1, 2, 3)
    quath qh = (1, 0.1, 0.2, 0.3)
    half h = 0.1
    float[] fs = [1, -2.5, 1e30, -inf, nan]
    int[] is = [1, 2147483648, -3.7]
    string[] ss = ["a\\nb", 'c', """d"""]
    asset a = @@@x@y@@@
    variantSet "look" = {
        "a" { def Mesh "VA" { int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] } }
        "b" ( kind = "x" ) { def Mesh "VB" { int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 2, 1]
            point3f[] points = [(0,0,0), (2,0,0), (0,2,0)] } }
    }
}
def Xform "E" ( variants = { string look = "" } prepend variantSets = "look" prepend references = </F> ) {
    variantSet "look" = { "a" { def Mesh "EA" { int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] } } }
}
class "F" ( variants = { string look = "a" } ) { }
def Mesh "sm_bolt_mesh_12" { int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] }
def "B" { reorder nameChildren = ["C"] def Mesh "C" { int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] } }
''',
    'nums.usda': '''#usda 1.0
def Xform "N"
{
    half h1 = 0.00001
    half h2 = -0.0000001
    half[] hs = [0.00002, 0.5, -0.00003]
    int64 n1 = -5
    int64 n2 = -2147483647
    double d1 = 1234567890123.456
    double d2 = -98765432109876.54
    float f1 = 0.000123456789012345678
    half[] hsub = [%s]
    def Mesh "M"
    {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0,0,0), (1,0,0), (0,1,0)]
    }
}
''' % ', '.join(['0.00006', '0.00003', '-0.00005'] * 400),
    'var_sub.usda': '''#usda 1.0
def Xform "E" ( variants = { string look = "a" } prepend variantSets = "look" ) {
    variantSet "look" = { "a" { def Mesh "EA" { int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] } } }
}
''',
    'var.usda': '''#usda 1.0
( subLayers = [@./var_sub.usda@] )
over "E" ( variants = { string look = "" } ) { }
''',
    'bodies.usda': '''#usda 1.0
( upAxis = "Z" metersPerUnit = 0.01 )
def Xform "Robot" ( prepend apiSchemas = ["PhysicsRigidBodyAPI", "PhysicsMassAPI"] ) {
    float physics:mass = 4
    rel material:binding:physics = </Robot/PM>
    def Mesh "Base" {
        int[] faceVertexCounts = [3, 3]
        int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]
        point3f[] points = [(0,0,0), (100,0,0), (100,100,0), (0,100,0)]
        uniform token physics:approximation = "convexHull"
    }
    def Mesh "Screw" {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
        float physics:mass = 0.01
    }
    def Xform "Link" ( prepend apiSchemas = ["PhysicsRigidBodyAPI"] ) {
        double3 xformOp:translate = (0, 0, 50)
        uniform token[] xformOpOrder = ["xformOp:translate"]
        float physics:mass = 0.001
        bool physics:kinematicEnabled = 1
        def Mesh "L" {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (10,0,0), (10,10,10)]
            uniform token physics:approximation = "boundingSphere"
        }
    }
    def Xform "Off" ( prepend apiSchemas = ["PhysicsRigidBodyAPI"] ) {
        bool physics:rigidBodyEnabled = 0
        def Mesh "O" {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0,0,0), (10,0,0), (10,10,10)]
        }
    }
    def Scope "PM" {
        float physics:dynamicFriction = 0.7
        float physics:restitution = 0.2
    }
    def PhysicsRevoluteJoint "J1" {
        rel physics:body0 = </Robot>
        rel physics:body1 = </Robot/Link/L>
        point3f physics:localPos0 = (0, 0, 50)
        quatf physics:localRot0 = (0.7071068, 0.7071068, 0, 0)
        uniform token physics:axis = "Y"
        float physics:lowerLimit = -45
        float physics:upperLimit = inf
    }
    def PhysicsPrismaticJoint "J2" ( prepend apiSchemas = ["PhysicsDriveAPI:linear"] ) {
        rel physics:body1 = </Robot/Link>
        uniform token physics:axis = "Z"
        float physics:lowerLimit = -5
        float physics:upperLimit = 5
    }
    def PhysicsPrismaticJoint "J3" {
        rel physics:body0 = </Robot>
        rel physics:body1 = </Robot/Link>
        uniform token physics:axis = "X"
        float physics:lowerLimit = -5
        float physics:upperLimit = 5
    }
    def PhysicsRevoluteJoint "J4" ( prepend apiSchemas = ["PhysxMimicJointAPI:rotZ"] ) {
        rel physics:body0 = </Robot/Link>
        rel physics:body1 = </Robot/Screw>
    }
    def PhysicsSphericalJoint "J5" {
        bool physics:jointEnabled = 0
        rel physics:body0 = </Robot>
    }
    def PhysicsFixedJoint "J6" {
        rel physics:body0 = </Robot/Off>
        rel physics:body1 = </Robot>
    }
    def PhysicsFixedJoint "J7" {
        rel physics:body0 = </Robot/Link>
        rel physics:body1 = </Robot/Link>
    }
}''',
}

def s_edges():
    print('-- edge cases --', flush=True)
    d = os.path.join(T, 'edges')
    os.makedirs(d, exist_ok=True)
    pts = ', '.join('(%d, %d, 0)' % (k % 40, k // 40) for k in range(1030))
    from PIL import Image
    Image.new('RGBA', (6, 4), (200, 100, 50, 128)).save(os.path.join(d, 'tex.png'))
    for name, body in EDGES.items():
        if name == 'polys.usda':
            body = body % (', '.join(str(k) for k in range(1025)), pts)
        open(os.path.join(d, name), 'w').write(body)
    for name in EDGES:
        f = os.path.join(d, name)
        bad, n = import_ok(f)
        check(not bad and n > 0, '%s: %d objects, read back, saved again the same (%s)' % (name, n, bad[:3]))
        fs = [f]
        c = f[:-1] + 'c'
        if subprocess.run(['usdcat', f, '-o', c], capture_output=True, env=PXENV).returncode == 0:
            fs.append(c)
        g, _ = dumps(BIN, fs)
        check(all(g[x] is not None for x in fs), '%s: read (and its crate twin: %s)' % (name, len(fs) == 2))
    a, _, _ = bee_after(BIN, '', os.path.join(d, 'uvzero.usda'), tag='uv')
    uv = beefile.chunk(a, b'MUVS') or b''
    check(a and len(uv) > 0, 'UVs kept where every corner has one other than exactly 0, 0 (MUVS %d bytes)' % len(uv))
    r, lg = port('--op', 'file.import_usd %s' % os.path.join(d, 'polys.usda'))
    check('  usd: a mesh with bad indices left out: /R/Bad' in lg and '  usd: a mesh with bad indices left out: /R/Far' in lg
          and '  usd: a mesh with bad indices left out: /R/Short' in lg, 'bad counts and indices: those meshes left out, said so')
    check(' skipped' in lg and 'imported ' in lg, 'the console: "usd: n objects from m meshes, k skipped", "imported <path>"')


# ---- textures ------------------------------------------------------------------------------

TABLE = """#usda 1.0
def Mesh "Table" ( prepend apiSchemas = ["MaterialBindingAPI"] ) {
    int[] faceVertexCounts = [4]
    int[] faceVertexIndices = [0, 1, 2, 3]
    point3f[] points = [(0,0,0), (1,0,0), (1,1,0), (0,1,0)]
    texCoord2f[] primvars:st = [(0,0), (1,0), (1,1), (0,1)] ( interpolation = "vertex" )
    rel material:binding = </Looks/Wood>
}
def Scope "Looks" { def Material "Wood" {
    token outputs:surface.connect = </Looks/Wood/S.outputs:surface>
    def Shader "S" { uniform token info:id = "UsdPreviewSurface"
        color3f inputs:diffuseColor.connect = </Looks/Wood/D.outputs:rgb>
        float inputs:roughness.connect = </Looks/Wood/R.outputs:g>
        token outputs:surface }
    def Shader "St" { uniform token info:id = "UsdPrimvarReader_float2"
        token inputs:varname = "st"
        float2 outputs:result }
    def Shader "D" { uniform token info:id = "UsdUVTexture"
        asset inputs:file = @./textures/diff_1k.jpg@
        float2 inputs:st.connect = </Looks/Wood/St.outputs:result>
        float3 outputs:rgb }
    def Shader "R" { uniform token info:id = "UsdUVTexture"
        asset inputs:file = @./textures/rough_1k.jpg@
        float2 inputs:st.connect = </Looks/Wood/St.outputs:result>
        float outputs:g }
} }
"""


def s_tex():
    print('-- textures: capped --', flush=True)
    from PIL import Image
    dd = os.path.join(T, 'tex')
    os.makedirs(os.path.join(dd, 'textures'), exist_ok=True)
    big = os.path.join(dd, 'textures', 'diff_1k.jpg')
    rng = random.Random(SEED)
    im = Image.new('RGBA', (37, 20))
    im.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(37 * 20)])
    im.save(big, format='PNG')                      # (a PNG under a .jpg name: read by its bytes)
    Image.new('RGB', (40, 30), (90, 120, 200)).save(os.path.join(dd, 'textures', 'rough_1k.jpg'), format='JPEG')
    st = os.path.join(dd, 'table.usda')
    open(st, 'w').write(TABLE)
    code = 'op("file.usd_texture_size", "8")\nn = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\nop("file.save", "%s/s.bee")' % (st, dd)
    rc1, _ = run(BIN, code)
    cp = os.path.join(dd, 'textures', 'diff_1k.8.png')
    made = os.path.getmtime(cp) if os.path.exists(cp) else 0
    rc2, _ = run(BIN, code)            # (made once: the second reads it)
    again = os.path.getmtime(cp) if made else -1
    names = sorted(os.listdir(os.path.join(dd, 'textures')))
    caps = {x: Image.open(os.path.join(dd, 'textures', x)) for x in names if '.8.png' in x}
    check(rc1 == 0 and 'diff_1k.8.png' in caps and 'rough_1k.8.png' in caps, 'the capped copies made (%s)' % [x for x in names if '.8.' in x])
    check(caps and all(max(v.size) <= 8 for v in caps.values()) and all(len(set(v.convert('RGBA').tobytes()[i:i + 4] for i in range(0, 4 * v.size[0] * v.size[1], 4))) > 1 for k, v in caps.items() if k.startswith('diff')),
          'at most 8 a side, the pixels kept (%s)' % [v.size for v in caps.values()])
    check(made and made == again, 'made once: a second import reads the copy')
    sb = os.path.join(dd, 's.bee')
    imgs = (beefile.chunk(sb, b'IMGS') or b'') if os.path.exists(sb) else b''
    check(b'.8.png' in imgs, 'the scene loads the capped copy')
    for x in caps:
        os.remove(os.path.join(dd, 'textures', x))
    run(BIN, 'op("file.usd_texture_size", "4")\nop("file.import_usd", "%s")' % st)
    c4 = [x for x in os.listdir(os.path.join(dd, 'textures')) if '.4.png' in x]
    check(len(c4) == 2 and all(max(Image.open(os.path.join(dd, 'textures', x)).size) <= 4 for x in c4), 'a JPEG and a PNG capped to 4: %s' % c4)


# ---- undo ------------------------------------------------------------------------------------

VIEW = (212, 80, 1022, 630)     # (the 3D viewport of the default workspace: the console says what was done)


def s_undo():
    print('-- undo --', flush=True)
    st = stage()
    b = lambda n: os.path.join(T, n)
    from PIL import Image
    port('--op', 'file.save %s' % b('u0.bee'))
    shot0 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    port('--op', 'file.import_usd %s' % st, '--op', 'file.save %s' % b('u1.bee'))
    shot1 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    r, lg = port('--op', 'file.import_usd %s' % st, '--op', 'edit.undo', '--op', 'file.save %s' % b('u2.bee'))
    shot2 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    port('--op', 'file.import_usd %s' % st, '--op', 'edit.undo', '--op', 'edit.redo', '--op', 'file.save %s' % b('u3.bee'))
    shot3 = Image.open(b('u.ppm')).crop(VIEW).tobytes()
    n0, n1 = len(beefile.objects(b('u0.bee'))), len(beefile.objects(b('u1.bee')))
    bad2 = compare_bee(b('u0.bee'), b('u2.bee'))
    bad3 = compare_bee(b('u1.bee'), b('u3.bee'))
    check(n1 == n0 + 4 and not [x for x in bad2 if not x.startswith(('IMGS', 'UIDS', 'MATS', 'MGRF'))] and not bad3,
          'import, undo, redo: %d objects, %d, then the import\'s scene again chunk for chunk (%s %s)' % (n1, n0, bad2[:2], bad3[:2]))
    check(shot2 == shot0 and shot1 != shot0 and shot3 == shot1, 'the 3D view after undo is the view before the import; after redo, after it')
    port('--op', 'file.import_usd %s' % st, '--select', 'Top', '--key', 'tab', '--key', 'tab', '--op', 'edit.undo', '--op', 'file.save %s' % b('u4.bee'))
    n4 = len(beefile.objects(b('u4.bee'))) if os.path.exists(b('u4.bee')) else -1
    check(n4 == n0, 'undo after edit mode on and off: the import undone (%d objects)' % n4)
    r, lg = port('--op', 'file.import_usd /nonexistent/x.usda', '--op', 'file.save %s' % b('u5.bee'))
    check('could not read /nonexistent/x.usda' in lg and not compare_bee(b('u0.bee'), b('u5.bee')), 'a file that is not there: said so, the scene as it was')


# ---- the window -----------------------------------------------------------------------------

def s_window():
    print('-- the window --', flush=True)
    st = stage()
    r, lg = port('--drop', 'file://' + st + '\r\n')
    ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
    stat = next((ln.split('\t')[1] for ln in ui.splitlines() if ln.startswith('status\t')), '')
    check('imported ' + st in lg and stat.split('|')[1].split()[0] == '7', 'a dropped .usda is imported (%s)' % stat)
    r, lg = port('--click-label', 'File', '--click-label', 'Import')
    ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
    check('menuitem\tImport USD...\t' in ui and [ln for ln in ui.splitlines() if ln.startswith('menuitem\tImport USD...')][0].endswith('\ton'),
          'File > Import has Import USD..., not greyed')
    r, lg = port('--click-label', 'File', '--click-label', 'Import', '--click-label', 'Import USD...')
    ui = open(os.path.join(T, 'u.txt'), errors='replace').read()
    check('button\tOpen\t' in ui and 'button\tCancel\t' in ui and 'menuitem\t' not in ui, 'Import USD... offers the file browser (Open, Cancel)')


# ---- cycles ----------------------------------------------------------------------------------

def s_cycles():
    print('-- cycles, missing files --', flush=True)
    cyc = os.path.join(T, 'cyc')
    os.makedirs(cyc, exist_ok=True)
    mesh = 'def Mesh "M" { int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 2]\n point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] }'
    open(os.path.join(cyc, 'a.usda'), 'w').write('#usda 1.0\n( subLayers = [@./a.usda@, @./b.usda@] )\n'
                                                 'def Xform "A" ( prepend references = @./b.usda@</B> ) { %s }\n' % mesh)
    open(os.path.join(cyc, 'b.usda'), 'w').write('#usda 1.0\n( subLayers = [@./a.usda@] )\n'
                                                 'def Xform "B" ( prepend references = [@./a.usda@</A>, @./missing.usda@, </B>] ) { def Xform "C" ( prepend references = </B> ) {} }\n')
    t0 = time.time()
    bad, n = import_ok(os.path.join(cyc, 'a.usda'))
    check(not bad and n > 0 and time.time() - t0 < 60, 'reference and sublayer cycles, a missing file: imported, read back in %.1f s (%s)' % (time.time() - t0, bad[:2]))
    g, rc = dumps(BIN, [os.path.join(cyc, 'a.usda') + '.missing'])
    check(rc == 0 and list(g.values()) == [None], 'a missing file is not read')


def main():
    print('  %s\n  seed %d' % (BIN, SEED))
    only = os.environ.get('USD_ONLY', '')
    for s in (s_readers, s_pxr, s_damage, s_gen, s_stage, s_edges, s_tex, s_undo, s_window, s_cycles):
        if not only or s.__name__ in only.split(','):
            s()


try:
    main()
finally:
    shutil.rmtree(T, True)
print('usd: fails %d' % len(FAILS))
sys.exit(1 if FAILS else 0)
