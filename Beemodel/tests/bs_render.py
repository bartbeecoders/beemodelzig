#!/usr/bin/env python3
"""BeeScript's render and image builtins (src/bs_render.zig) run by BeeModel
(--eval, a temp HOME and XDG_RUNTIME_DIR each): vgeo vgstat probe probeinfo
probesample lightmap lmsample gpu render render_frames image imgsize
imgpixel. Normal calls, every argument count, wrong types and names, edge
values, damaged image files, random calls, garbage: each run ends cleanly (a
result or a script error, no crash, panic or timeout), a wrong call is
refused with an error. What the builtins can be held to on their own: the
pixels read back as the files written, the sizes asked for, the probes as
added, baked and saved files that open to the same answers, a DAG's state
as it is built, edited and cleared, and the scenes the scripts save read
back and come back the same through open and save.

    python3 tests/bs_render.py BIN [random-runs=150] [seed]

BR_ONLY=images,render,frames,probes,vgeo,gpu,args,random,fuzz runs some
sections. BEEMODEL_GPU is off for every run but the gpu section's.
"""
import math, os, random, re, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 150
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('BR_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beebr-', dir=os.environ.get('BR_TMP', '/tmp'))


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(s):
    return not ONLY or s in ONLY


def run(binary, args, timeout=300, gpu='off'):
    """One run with a HOME and XDG_RUNTIME_DIR of its own: (rc, stdout)."""
    h = tempfile.mkdtemp(dir=T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'))
    if gpu is None:
        env.pop('BEEMODEL_GPU', None)
    else:
        env['BEEMODEL_GPU'] = gpu
    try:
        r = subprocess.run([binary, *args], capture_output=True, timeout=timeout, env=env, cwd=h)  # (relative paths land in the temp HOME)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout')
    shutil.rmtree(h, True)
    return out


def port(code, **k):
    return run(BIN, ['--eval', code], **k)


def clean(r):
    """A run that ended as a program should: a result or a script error, no
    crash (a signal), panic, safety check or timeout."""
    rc, out = r
    return rc in (0, 1) and 'panic' not in out and 'reached unreachable' not in out and 'integer overflow' not in out


def same(code, what=None, clean_=False, fails=False, **k):
    """BeeModel runs code cleanly: (ok, its result). clean_: and with no error;
    fails: refused with a script error (exit 1, "error:")."""
    b = port(code, **k)
    ok = clean(b)
    if clean_:
        ok = ok and b[0] == 0 and 'error:' not in b[1]
    if fails:
        ok = ok and b[0] == 1 and 'error:' in b[1]
    check(ok, (what or repr(code[:70])) + ('' if ok else f'\n         {b!r}'))
    return ok, b


def nums(out):
    """The numbers a run printed, in order (nil as None)."""
    return [None if w == 'nil' else float(w) for w in out.split()]


def scene(path):
    """A .bee file's chunks as a scene (as tests/bscript.py: objects with their
    meshes, the rest but the workspaces, thumbnail and view)."""
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<I', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], meshes[mi] if typ == 0 and mi < len(meshes) else None))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL') or not b:
            continue
        rest.setdefault(t, []).append(b)
    return recs, rest


def same_files(code, what, chunks=None):
    """code + a save: a clean run, a file that reads back, and opened and saved
    again the same scene (chunks: those that must be there)."""
    pa, pb = os.path.join(T, 'sa.bee'), os.path.join(T, 'sb.bee')
    for p in (pa, pb):
        if os.path.exists(p):
            os.remove(p)
    a = port(code + f'\nop("file.save", "{pa}")')
    ok = a[0] == 0 and 'error:' not in a[1] and os.path.exists(pa)
    why = '' if ok else f': {a!r}'
    if ok:
        try:
            ra, xa = scene(pa)
        except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
            ok, why = False, f': it does not read back ({e})'
    if ok:
        miss = [t.decode() for t in chunks or () if t not in xa]
        if miss:
            ok, why = False, f': no {", ".join(miss)} chunk'
    if ok:
        b = port(f'op("file.open", "{pa}")\nop("file.save", "{pb}")')
        if b[0] != 0 or not os.path.exists(pb):
            ok, why = False, f': opened and saved again {b!r}'
        elif scene(pb) != (ra, xa):
            ok, why = False, ': opened and saved again, the scene differs'
    check(ok, what + why)
    return ok


# ---- image files ------------------------------------------------------------------------

def png(path, w, h, px, ctype=6, depth=8, extra=b''):
    """A PNG of colour type ctype from rows of bytes (px: one bytes per row)."""
    raw = b''.join(b'\0' + r for r in px)

    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, ctype, 0, 0, 0)) + extra + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')
    open(path, 'wb').write(data)
    return data


def hdr(path, w, h, rgb):
    """A Radiance HDR (flat RGBE scanlines)."""
    def rgbe(r, g, b):
        v = max(r, g, b)
        if v < 1e-32:
            return bytes(4)
        import math
        m, e = math.frexp(v)
        s = m * 256.0 / v
        return bytes([int(r * s), int(g * s), int(b * s), e + 128])
    body = b''.join(rgbe(*rgb[i]) for i in range(w * h))
    open(path, 'wb').write(b'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n' + f'-Y {h} +X {w}\n'.encode() + body)


def make_images():
    d = os.path.join(T, 'img')
    os.makedirs(d)
    rnd = random.Random(7)
    rows = [bytes(rnd.randrange(256) for _ in range(5 * 4)) for _ in range(3)]
    png(f'{d}/rgba.png', 5, 3, rows, 6)
    png(f'{d}/rgb.png', 4, 2, [bytes(rnd.randrange(256) for _ in range(12)) for _ in range(2)], 2)
    png(f'{d}/grey.png', 3, 3, [bytes(rnd.randrange(256) for _ in range(3)) for _ in range(3)], 0)
    png(f'{d}/ga.png', 2, 2, [bytes(rnd.randrange(256) for _ in range(4)) for _ in range(2)], 4)
    pal = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9])

    def chunk(t, x):
        return struct.pack('>I', len(x)) + t + x + struct.pack('>I', zlib.crc32(t + x) & 0xffffffff)
    png(f'{d}/pal.png', 4, 1, [bytes([0, 1, 2, 3])], 3, 8, chunk(b'PLTE', pal) + chunk(b'tRNS', bytes([255, 128])))
    png(f'{d}/a.b.c.png', 1, 1, [b'\x01\x02\x03\x04'], 6)
    png(f'{d}/' + 'n' * 40 + '.png', 1, 1, [b'\x05\x06\x07\x08'], 6)
    png(f'{d}/.png', 1, 1, [b'\x09\x0a\x0b\x0c'], 6)
    png(f'{d}/noext', 1, 1, [b'\x09\x0a\x0b\x0c'], 6)
    hdr(f'{d}/sky.hdr', 3, 2, [(0.5, 1.0, 2.0), (10.0, 0.25, 0.0), (0, 0, 0), (1e-3, 2e-3, 3e-3), (100, 50, 25), (0.1, 0.2, 0.3)])
    try:
        from PIL import Image
        im = Image.new('RGB', (8, 8))
        im.putdata([(x * 30, y * 30, (x * y) % 256) for y in range(8) for x in range(8)])
        im.save(f'{d}/photo.jpg', quality=90)
        im.save(f'{d}/prog.jpg', quality=90, progressive=True)
        im.convert('L').save(f'{d}/greyj.jpg', quality=90)
    except ImportError:
        pass
    good = open(f'{d}/rgba.png', 'rb').read()
    open(f'{d}/trunc.png', 'wb').write(good[:len(good) // 2])
    open(f'{d}/garbage.png', 'wb').write(bytes(rnd.randrange(256) for _ in range(300)))
    open(f'{d}/magic.png', 'wb').write(good[:8] + bytes(rnd.randrange(256) for _ in range(200)))
    open(f'{d}/empty.png', 'wb').write(b'')
    open(f'{d}/short.hdr', 'wb').write(b'#?RADIANCE\n\n-Y 9 +X 9\n\x01\x02')
    open(f'{d}/badcrc.png', 'wb').write(good[:20] + bytes([good[20] ^ 0xff]) + good[21:])
    os.makedirs(f'{d}/dir.png')
    return d


BAD = ('trunc.png', 'garbage.png', 'magic.png', 'empty.png', 'short.hdr', 'badcrc.png', 'prog.jpg')


def expected(path):
    """The file's pixels as (w, h, rows of RGBA) read here, and how near
    BeeModel must come (8-bit: exactly, JPEG: its decoder's rounding, HDR:
    linear, alpha 1); None for what is not read here."""
    if path.endswith('.hdr'):
        data = open(path, 'rb').read()
        m = re.search(rb'-Y (\d+) \+X (\d+)\n', data)
        if not m:
            return None
        h, w = int(m.group(1)), int(m.group(2))
        body = data[m.end():]
        if len(body) < w * h * 4:
            return None
        px = []
        for i in range(w * h):
            r, g, b, e = body[i * 4:i * 4 + 4]
            f = math.ldexp(1, e - 136) if e else 0
            px.append(((r + 0.5) * f if e else 0, (g + 0.5) * f if e else 0, (b + 0.5) * f if e else 0, 1, f * 1.01 + 1e-9))
        return w, h, px, 'hdr'
    try:
        from PIL import Image
        im = Image.open(path)
        im.load()
    except Exception:  # noqa: BLE001 (damaged: no pixels to hold it to)
        return None
    q = im.convert('RGBA')
    return im.size[0], im.size[1], [q.getpixel((x, y)) for y in range(im.size[1]) for x in range(im.size[0])], 'jpeg' if im.format == 'JPEG' else 'png'


def near(a, b, kind, step=0):
    if kind == 'hdr':
        return abs(a - b) <= step  # (a mantissa step: decoders round m or m + 0.5)
    return abs(a - b) <= (8 if kind == 'jpeg' else 0)


def s_images():
    print('-- image imgsize imgpixel --')
    d = make_images()
    names = sorted(f for f in os.listdir(d) if not f.startswith('dir'))
    for f in names:
        code = (f'i = image("{d}/{f}")\nprint(i, imgsize(i, 0), imgsize(i, 1), imgsize(i, -1))\n'
                'w = imgsize(i, 0)\nh = imgsize(i, 1)\nfor y in -1..h + 1 { for x in -1..w + 1 { print(x, y, imgpixel(i, x, y, -1), imgpixel(i, x, y, 0), imgpixel(i, x, y, 1), imgpixel(i, x, y, 2), imgpixel(i, x, y, 3), imgpixel(i, x, y, 4)) } }')
        ok, r = same(code, f'{f}: loaded, or refused cleanly', clean_=f not in BAD)
        ex = expected(f'{d}/{f}') if f not in BAD else None
        if not ok or ex is None or r[0] != 0:
            continue
        w, h, px, kind = ex
        lines = r[1].splitlines()
        first = lines[0].split()
        why = []
        if [float(x) for x in first[1:]] != [w, h, h]:
            why.append(f'the size {first[1:]} (made {w} x {h}; imgsize(i, -1) the height)')
        for ln in lines[1:]:
            v = [float(x) for x in ln.split()]
            x, y, ch = int(v[0]), int(v[1]), v[2:]
            if not (0 <= x < w and 0 <= y < h):
                if any(c != -1 for c in ch):
                    why.append(f'outside ({x}, {y}): {ch}')
                continue
            want_ = px[y * w + x]
            if ch[0] != -1 or ch[5] != -1:
                why.append(f'({x}, {y}): channels -1 and 4 not -1: {ch}')
            if not all(near(ch[1 + c], want_[c], kind, want_[4] if kind == 'hdr' else 0) for c in range(4)):
                why.append(f'({x}, {y}): {ch[1:5]} where the file holds {want_[:4]}')
        check(not why, f'{f}: its size, and every pixel and channel as the file holds ({kind}; outside: -1)' + ('' if not why else ': ' + '; '.join(why[:3])))
    ok, r = same(f'print(image("{d}/rgba.png"), image("{d}/rgba.png"), image("{d}/rgb.png"), image("{d}/rgba.png"))', 'the same file four times', clean_=True)
    nm = r[1].split()
    check(ok and len(nm) == 4 and len(set(nm)) == 4, f'  each load a new image, each its own name ({nm})')
    same(f'image("{d}/dir.png")', 'a folder: could not load', fails=True)
    same(f'image("{d}/missing.png")', 'a missing file: could not load', fails=True)
    same('image("")', 'an empty path', fails=True)
    same(f'image("~/nope.png")', '~ expanded, not there', fails=True)
    same(f'print(image(" {d}/rgb.png "))', 'spaces round the path')
    same('print(imgsize("nope", 0))', 'no image called', fails=True)
    same('print(imgpixel("nope", 0, 0, 0))', 'imgpixel: no image called', fails=True)
    same(f'i = image("{d}/rgba.png")\nprint(imgpixel(i, 1e10, 0, 0), imgpixel(i, 0, -1e10, 0), imgpixel(i, 0, 0, 1e30), imgsize(i, 1e30), imgsize(i, 0.9), imgsize(i, -0.9), imgpixel(i, 0.99, 0.99, 0.99))',
         'huge and fractional indices', clean_=True)
    same(f'i = image("{d}/rgba.png")\nprint(imgpixel(i, "a", 0, 0))', 'a text for a number', fails=True)
    same(f'print(imgsize(5, 0))', 'a number for the name', fails=True)
    same(f'print(image(nil))', 'nil for the path', fails=True)
    same(f'i = image("{d}/rgba.png")\nprint(imgsize(i))', 'imgsize: one argument', fails=True)
    same(f'i = image("{d}/rgba.png")\nprint(imgpixel(i, 0, 0))', 'imgpixel: three arguments', fails=True)
    same(f'print(image())', 'image: none', fails=True)
    same(f'print(image("{d}/rgba.png", 1))', 'image: two', fails=True)
    # the images in the .bee: IMGS and IMGD written, read back, saved again the same
    same_files(f'image("{d}/rgba.png")\nimage("{d}/rgba.png")\nimage("{d}/sky.hdr")\nimage("{d}/a.b.c.png")', 'the images saved: read back, the same saved again', [b'IMGS'])
    # damaged: everything but a crash, also many at once
    code = '\n'.join(f'print(image("{d}/{f}"))' for f in ('trunc.png', 'garbage.png', 'magic.png', 'empty.png', 'short.hdr', 'badcrc.png') if os.path.exists(f'{d}/{f}'))
    for line in code.splitlines():
        same(line, 'damaged: ' + line.split('/')[-1][:-3])
    same(code, 'damaged: all at once')


def s_render():
    print('-- render (the path tracer into a PNG) --')
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        print('  (no PIL / numpy: skipped)')
        return
    d = os.path.join(T, 'r')
    os.makedirs(d)
    sc = 'add("sphere", "S", 2, 0, 0)\nadd("torus", "To", -2, 0.5, 0)\n'
    cases = [('default', '', '160, 90, 32', (160, 90)), ('denoised', sc, '160, 90, 32, 1', (160, 90)),
             ('camera', sc + 'add("camera", "Cam", 6, 3, 6)\nrotate("Cam", -20, 45, 0)\nop("view.camera")\n', '120, 120, 24', (120, 120)),
             ('defaults', '', '', (640, 360))]  # (render's defaults: 640 x 360, bs_render.zig)
    for tag, pre, args, size in cases:
        b = os.path.join(d, f'p_{tag}.png')
        arg = f', {args}' if args else ''
        ob = port(pre + f'ms = render("{b}"{arg})\nprint(ms >= 0, ms < 600000)')
        check(ob == (0, '1 1\n'), f'{tag}: rendered, its time in range ({ob!r})')
        if not os.path.exists(b):
            check(False, f'{tag}: the PNG written')
            continue
        ib = Image.open(b)
        check(ib.size == size, f'{tag}: the size asked for {size} ({ib.size} {ib.mode})')
        y = np.asarray(ib.convert('RGB')).astype(float)
        check(np.isfinite(y).all() and y.max() > 0 and y.std() > 0, f'{tag}: a picture, not one colour (mean {y.mean():.1f}, deviation {y.std():.1f})')
    # no samples: the film as it starts (black)
    b = os.path.join(d, 'p0.png')
    ob = port(f'print(render("{b}", 12, 7, 0) >= 0)')
    check(ob == (0, '1\n'), f'0 samples: {ob!r}')
    if os.path.exists(b):
        check(not np.asarray(Image.open(b).convert('RGB')).any(), '0 samples: a black picture')
    # what fails: could not render or write
    for args in ('0, 10, 4', '10, 0, 4', '1e10, 6, 1', '6, 1e10, 1'):
        same(f'print(render("{d}/f.png", {args}))', f'render({args}): could not render or write', fails=True)
    # (a film the path tracer cannot hold, or no samples asked: refused, as filmOk)
    for args in ('-5, 10, 4', '100000, 100000, 1', '8, 8, -1'):
        b = port(f'print(render("{d}/f.png", {args}))', timeout=60)
        check(b == (1, f'error: line 1: render: could not render or write {d}/f.png\n'), f'render({args}): it says it could not render ({b!r})')
    same(f'print(render("{d}/nodir/x.png", 8, 8, 1))', 'a folder that is not there', fails=True)
    same(f'print(render("{d}", 8, 8, 1))', 'a folder for the file', fails=True)
    same('op("file.save", "~/BeeModel/a.bee")\nprint(render("~/BeeModel/x.png", 8, 8, 1) >= 0)', '~ expanded; file.save made ~/BeeModel (op_save: default_dir)', clean_=True)
    same('print(render("~/BeeModel/x.png", 8, 8, 1) >= 0)', 'without it: no ~/BeeModel, could not write', fails=True)
    same('print(render(5))', 'a number for the path', fails=True)
    same('print(render("x", "y"))', 'the numbers are read first', fails=True)
    same(f'print(render("{d}/x.png", 8, 8, 1, 0, 9))', 'six arguments', fails=True)
    same('print(render())', 'none', fails=True)
    # the scene saved after a render: nothing changed by it
    pa, pb = os.path.join(T, 'r_before.bee'), os.path.join(T, 'r_after.bee')
    r = port(sc + f'op("file.save", "{pa}")\nrender("{d}/s.png", 16, 9, 2)\nop("file.save", "{pb}")')
    ok = r[0] == 0 and os.path.exists(pa) and os.path.exists(pb)
    check(ok and scene(pa) == scene(pb), f'a render changes nothing in the scene ({r!r})')
    same_files(sc + f'render("{d}/s2.png", 16, 9, 2)', 'the scene after a render: read back, the same saved again')


def s_frames():
    print('-- render_frames --')
    d = os.path.join(T, 'f')
    os.makedirs(d)

    def listing(p):
        return sorted(os.listdir(p)) if os.path.isdir(p) else None
    pre = 'add("sphere", "S", 2, 0, 0)\nkey("S:x", 1, 0)\nkey("S:x", 3, 2)\n'
    for tag, args, n, last in (('three', '1, 3, 32, 18, 4', 3, 3), ('negative', '-2, 1, 16, 9, 2', 4, 1), ('one', '5, 5, 16, 9, 1, 1', 1, 5), ('slash', '1, 2, 16, 9, 2', 2, 2)):
        b = os.path.join(d, 'p_' + tag)
        sl = '//' if tag == 'slash' else ''
        ob = port(pre + f'ms = render_frames("{b}{sl}", {args})\nprint(ms >= 0, frame())')
        check(ob == (0, f'1 {last}\n'), f'{tag}: rendered, the frame left at the last, {last} ({ob!r})')
        check(listing(b) is not None and len(listing(b)) == n and all(f.endswith('.png') for f in listing(b)), f'{tag}: a PNG a frame, {n}: {listing(b)}')
    same(pre + 'print(frame())\nms = render_frames("%s/x", 4, 3, 8, 8, 1)\nprint(ms)' % d, 'first after last: could not render or write', fails=True)
    same('print(render_frames("", 1, 1, 8, 8, 1))', 'an empty folder', fails=True)
    same(f'print(render_frames("{d}/z", 1, 1, 0, -5, 0, 7) >= 0)', 'width, height, samples at least 1, denoise as given', clean_=True)
    same(f'print(render_frames("{d}/z2", 1, 1, 1e12, 1e12, 1) >= 0)', 'a huge width and height: the minimum integer, so 1', clean_=True)
    same('print(render_frames(1))', 'a number for the folder', fails=True)
    same('print(render_frames())', 'none', fails=True)
    same(f'print(render_frames("{d}/q", 1, 1, 8, 8, 1, 0, 3))', 'eight arguments', fails=True)
    same('op("anim.range", "1 2")\nprint(render_frames("%s/d", nil))' % d, 'nil for first', fails=True)
    # the defaults: the animation's range and the render settings
    b = os.path.join(d, 'p_def')
    ob = port('op("anim.range", "3 4")\nop("render.settings", "16 9 2")\nprint(render_frames("%s") >= 0)' % b)
    check(ob == (0, '1\n') and listing(b) == ['0003.png', '0004.png'], f'the defaults: frames {listing(b)}')
    try:
        from PIL import Image
        if listing(b):
            sz = [Image.open(f'{b}/{f}').size for f in listing(b)]
            check(all(x == (16, 9) for x in sz), f'  at the render settings\' size: {sz}')
    except ImportError:
        pass


# ---- probes and the lightmap: a scene baked, saved, opened and asked again --------------

SCENE = '''delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 6)
add("cube", "Roof", 0, 2, 0)
scale("Roof", 2, 0.1, 2)
add("sphere", "Ball", 3, 1, 1)
scale("Ball", 0.6)
op("probe.add", "irradiance 0 1 0 5 0.9 5 4 3 4")
op("probe.add", "reflection 3 1.5 0 2 1.5 2")
'''


def queries():
    q = ['print(probe(0), probe(1), probe(2), probe(3), probe(6), probe(7), probe(-1), lightmap(0), lightmap(1), lightmap(2), lightmap(4), lightmap(5), lightmap(-3))']
    q.append('s = ""\nfor n in -1..4 { for w in -1..12 { s = s + " " + str(probeinfo(n, w)) } }\nprint(s)')
    pts = [(0, 0.1, 0, 0, 1, 0), (2, 1, 1, 0.3, 1, -0.2), (3, 1.5, 0, 1, 0, 0), (3, 1.5, 0, 0, 0, 0), (-4, 0.5, 3, 0, 1, 0), (40, 0, 0, 0, 1, 0), (0, 1, 0, 1e30, 1, 0)]
    for p in pts:
        a = ', '.join(map(str, p))
        q.append(f'print(probesample(0, {a}, 0), probesample(0, {a}, 1), probesample(0, {a}, 2), probesample(0, {a}, 3), probesample(1, {a}, 0), probesample(1, {a}, 2), probesample(1, {a}, -1), probesample(7, {a}, 1))')
    for o, p in (('Floor', (0, 0, 0)), ('Floor', (1.5, 0.01, -2.2)), ('Floor', (1.5, 0.2, -2.2)), ('Roof', (0, 2.1, 0)), ('Roof', (0.5, 1.9, 0.5)), ('Ball', (3, 1.6, 1)), ('Floor', (99, 0, 0))):
        a = ', '.join(map(str, p))
        q.append(f'print(lmsample("{o}", {a}, 0), lmsample("{o}", {a}, 1), lmsample("{o}", {a}, 2), lmsample("{o}", {a}, 3), lmsample("{o}", {a}, -1))')
    return '\n'.join(q)


def s_probes():
    print('-- probe probeinfo probesample lightmap lmsample --')
    ob = os.path.join(T, 'baked.bee')
    ok, r = same('print(probe(0), probe(4), probe(5), lightmap(0), probeinfo(1, 0), probesample(0, 0, 0, 0, 0, 1, 0, 0), probesample(2, 0, 0, 0, 0, 1, 0, 0), lmsample("Cube", 0, 0, 0, 0))', 'none', clean_=True)
    check(len(r[1].split()) == 8 and set(r[1].split()) <= {'0', 'nil'}, f'  none: zeros and nils ({r[1].strip()!r})')
    same(SCENE + queries(), 'probes not baked: counts, boxes, samples', clean_=True)
    # as added: irradiance 0 1 0, half 5 0.9 5, 4 x 3 x 4 points; reflection 3 1.5 0, half 2 1.5 2
    ok, r = same(SCENE + 'print(probe(0), probe(2), probe(3), probe(6))\nfor n in 1..3 { s = ""\n for w in 2..11 { s = s + " " + str(probeinfo(n, w)) }\n print(s) }\nprint(probeinfo(0, 2), probeinfo(3, 2))', 'the probes as added', clean_=True)
    want_ = ['2 1 1 48', '0 1 0 5 0.9 5 4 3 4', '3 1.5 0 2 1.5 2 1 1 1', 'nil nil']
    check([ln.strip() for ln in r[1].splitlines()] == want_, f'  counts, centres, half sizes, grid points (probe 0, 3: nil): {r[1].splitlines()}')
    r = port(SCENE + f'op("probe.bake", "64")\nop("lightmap.bake", "64 32")\nprint(probe(1), lightmap(1), lightmap(4), probeinfo(1, 1))\n' + queries() + f'\nop("file.save", "{ob}")')
    check(r[0] == 0 and os.path.exists(ob), f'baked and saved ({r[0]} {r[1][-120:]!r})')
    if not os.path.exists(ob):
        return
    first, rest = r[1].split('\n', 1)
    check(first.split() == ['2', '64', '32', '64'], f'  the two probes baked, the lightmap 64 wide, 32 rays a texel, 64 samples ({first!r})')
    bad = [w for w in rest.split() if w != 'nil' and not math.isfinite(float(w))]
    check(not bad, f'  every answer a number or nil, finite ({bad[:4]})')
    ok, r2 = same(f'op("file.open", "{ob}")\n' + queries(), 'its file opened', clean_=True)
    # (the first line: counts, and the lightmap bake's own texels and rays, not kept in a file)
    check(r2[1].split('\n', 1)[1:] == rest.split('\n', 1)[1:], 'its file opened: the probes and lightmap answer as before it was saved, bit for bit')
    same(f'op("file.open", "{ob}")\nprint(probe(4), probe(5), lightmap(3))', 'the bake\'s time and paths after opening', clean_=True)
    ok, r = same(f'op("file.open", "{ob}")\nmove("Floor", 0, 1, 0)\nprint(lmsample("Floor", 0, 1, 0, 0) > 0, lmsample("Floor", 0, 0, 0, 0))', 'lmsample: the object where it is now', clean_=True)
    check(r[1].split() == ['1', 'nil'], f'  moved up 1: lit where it is, nothing where it was ({r[1].strip()!r})')
    same(f'op("file.open", "{ob}")\nprint(lmsample("nope", 0, 0, 0, 0))', 'lmsample: no object named', fails=True)
    same(f'op("file.open", "{ob}")\nprint(lmsample("Floor", 0, 0, "z", 0))', 'lmsample: a text for a number', fails=True)
    # the reference traced now: the path tracer, so finite and not negative
    code = f'op("file.open", "{ob}")\nprint(probesample(2, 0, 0.1, 0, 0, 1, 0, 0, 4096), probesample(2, 0, 0.1, 0, 0, 1, 0, 1, 4096), probesample(2, 3, 1.5, 0, 1, 0, 0, 2, 4096), probesample(2, 0, 1.89, 0, 0, -1, 0, 0, 4096))'
    b = port(code)
    try:
        y = [float(v) for v in b[1].split()]
        check(b[0] == 0 and len(y) == 4 and all(math.isfinite(v) and v >= 0 for v in y), f'probesample(2 ...): the irradiance traced now, finite, not negative ({y})')
    except ValueError:
        check(False, f'probesample(2 ...): {b!r}')
    same(f'op("file.open", "{ob}")\nprint(probesample(2, 0, 0.1, 0, 0, 1, 0, 0, 0), probesample(2, 0, 0.1, 0, 0, 1, 0, 5, 16), probesample(2, 0, 0.1, 0, 0, 1, 0, -1, 16))', 'probesample(2 ...): no rays, a channel outside', clean_=True)
    same_files(f'op("file.open", "{ob}")', 'the baked file: read back, the same saved again')


def s_vgeo():
    print('-- vgeo vgstat --')
    # (vgeo(name, 0): 0 no DAG, 2 built, 3 out of date: vgeo.zig stateOf; 12: crack-free)
    sc = ('n = add("torus", "T")\nmodifier(n, "subsurf")\nmodset(n, 0, "levels", 2)\nmodapply(n, 0)\n'
          'n = add("grid", "G", 8, 0, 0)\nmodifier(n, "subsurf")\nmodset(n, 0, "levels", 1)\nmodapply(n, 0)\nadd("cube", "C", -8, 0, 0)\nadd("light", "L")\n')
    ks = list(range(-1, 16)) + [100, 101, 102, 103, 200, 201, 202, 300, 301, 302, 400, 401, 402, 500, 501, 502, 599, 1000]
    ks = [k for k in ks if k != 6]
    qs = '\n'.join('print("%s", %s)' % (o, ', '.join(f'vgeo("{o}", {k})' for k in ks[j:j + 15])) for o in ('T', 'G', 'C', 'L') for j in range(0, len(ks), 15))
    ok, r = same(sc + qs, 'no DAGs', clean_=True)
    check(all(w in ('0', 'T', 'G', 'C', 'L') for w in r[1].split()), '  no DAGs: every k 0')
    build = sc + 'select("T")\nop("vgeo.build")\nselect("G")\nop("vgeo.build")\n'
    ok, built = same(build + qs, 'built: state, clusters, levels, groups, triangles, KB, error, roots, the largest cluster, crack-free, per level (but the time, 6)', clean_=True)
    ok, r = same(build + 'print(vgeo("T", 0), vgeo("G", 0), vgeo("C", 0), vgeo("L", 0), vgeo("T", 12), vgeo("G", 12))', 'built: the states', clean_=True)
    check(r[1].split() == ['2', '2', '0', '0', '1', '1'], f'  T and G built (2), C and L none (0), each crack-free ({r[1].strip()!r})')
    ok, r = same(build + 'print(vgeo("T", 6) >= 0, vgeo("T", 0))\nvmove("T", 0, 9, 9, 9)\nprint(vgeo("T", 0), vgeo("T", 1), vgeo("G", 0))', 'edited since', clean_=True)
    check(r[1].split()[:3] == ['1', '2', '3'] and r[1].split()[-1] == '2', f'  edited since: T out of date (3), G still built ({r[1].strip()!r})')
    ok, r = same(build + 'select("T")\nop("vgeo.clear")\nprint(vgeo("T", 0), vgeo("T", 2), vgeo("G", 0))', 'cleared', clean_=True)
    check(r[1].split() == ['0', '0', '2'], f'  cleared: T none (0), G still built ({r[1].strip()!r})')
    f = os.path.join(T, 'vg.bee')
    r = port(build + f'op("file.save", "{f}")')
    check(r[0] == 0 and os.path.exists(f), 'built and saved')
    if r[0] == 0 and os.path.exists(f):
        ok, r = same(f'op("file.open", "{f}")\n' + qs, 'its file opened', clean_=True)
        check(r[1] == built[1], '  its file opened: the same answers as when built')
        ok, r = same(f'op("file.open", "{f}")\nvmove("G", 3, 0, 1, 0)\nprint(vgeo("G", 0), vgeo("T", 0))', 'its file, then an edit', clean_=True)
        check(r[1].split() == ['3', '2'], f'  its file, then an edit: G out of date (3), T built ({r[1].strip()!r})')
    same('print(vgeo("nope", 0))', 'no object named', fails=True)
    same('print(vgeo("Cube", "x"))', 'a text for k', fails=True)
    same('print(vgeo(1, 0))', 'a number for the name', fails=True)
    same('print(vgeo("Cube"))', 'one argument', fails=True)
    ok, r = same('s = ""\nfor k in -2..20 { s = s + " " + str(vgstat(k)) }\nprint(s)', 'vgstat: no frame drawn', clean_=True)
    check(all(float(w) >= 0 for w in r[1].split()), f'  vgstat: no frame drawn (headless): no negative answers ({r[1].strip()!r})')
    same('print(vgstat("a"))', 'vgstat: a text', fails=True)
    same('print(vgstat())', 'vgstat: none', fails=True)


def s_gpu():
    print('-- gpu --')
    ok, r = same('s = ""\nfor k in -1..40 { s = s + " " + str(gpu(k)) }\nprint(s)', 'BEEMODEL_GPU=off', clean_=True)
    check(set(r[1].split()) == {'0'}, '  BEEMODEL_GPU=off: every counter 0, the helper not started')
    same('print(gpu("a"))', 'a text', fails=True)
    same('print(gpu())', 'none', fails=True)
    same('print(gpu(nil))', 'nil', fails=True)
    helper = os.path.join(os.path.dirname(os.path.realpath(BIN)), 'beemodel-gpu')
    if not os.path.exists(helper):
        print('  (no GPU helper built: the GPU path not tried)')
        return

    def helpers():
        # (this test's helpers only: their HOME under T; other runs may have their own)
        out = set()
        for pid in subprocess.run(['pgrep', '-f', 'beemodel-gpu'], capture_output=True, text=True).stdout.split():
            try:
                if f'HOME={T}/'.encode() in open(f'/proc/{pid}/environ', 'rb').read():
                    out.add(pid)
            except OSError:
                pass
        return out
    before = helpers()
    # (each printed test 1: started or not, the counts agree with it)
    code = 'up = gpu(0)\nprint(up, gpu(1) > 0 or up == 0)\nadd("sphere", "S", 2, 0, 0)\nms = render("%s", 64, 36, 16)\nprint(gpu(6) == up, gpu(2) > 0 or up == 0, gpu(4) >= 16 * up)'
    b = run(BIN, ['--eval', code % os.path.join(T, 'gp.png')], gpu=None)
    lines = b[1].split('\n')
    check(b[0] == 0 and len(lines) >= 2 and lines[0].split()[1:] == ['1'] and lines[1].split() == ['1', '1', '1'],
          f'the helper started, a render on it: device, runs, samples and this render counted ({b!r})')
    import time
    time.sleep(0.5)
    left = helpers() - before
    check(not left, f'no helper left running ({sorted(left)})')


# ---- every builtin: argument counts and types -------------------------------------------

SPECS = {'vgeo': 2, 'vgstat': 1, 'probe': 1, 'probeinfo': 2, 'probesample': (8, 9), 'lightmap': 1, 'lmsample': 5, 'gpu': 1,
         'render': (1, 5), 'render_frames': (1, 7), 'image': 1, 'imgsize': 2, 'imgpixel': 4}


def s_args():
    print('-- argument counts, types --')
    for nm, n in SPECS.items():
        lo, hi = (n, n) if isinstance(n, int) else n
        for k in (lo - 1, hi + 1):
            if k >= 0:
                same(f'print({nm}({", ".join(["1"] * k)}))', f'{nm} with {k} arguments: refused', fails=True)
        for bad in ('"x"', 'nil', '1e300'):
            for pos in range(hi):
                args = ['"Cube"' if (nm in ('vgeo', 'lmsample') and p == 0) else ('"img"' if nm in ('imgsize', 'imgpixel') and p == 0 else ('"' + T + '/a.png"' if nm in ('render', 'render_frames', 'image') and p == 0 else '1')) for p in range(hi)]
                if nm in ('render', 'render_frames') and (bad == '1e300' or (bad == '"x"' and pos == 0)):
                    continue  # (a render that works: slow, and nothing to learn)
                args[pos] = bad
                same(f'print({nm}({", ".join(args)}))', f'{nm}: {bad} in argument {pos + 1}')
    # NaN and the infinities (made by the language)
    for nm in ('probe', 'lightmap', 'vgstat', 'gpu'):
        same(f'n = 0\nx = sqrt(0 - 1)\nprint({nm}(x), {nm}(1e300), {nm}(-1e300), {nm}(4294967296 + 1))', f'{nm}: NaN and huge')
    same('x = sqrt(0 - 1)\nprint(probeinfo(x, 0), probeinfo(1, x), probesample(x, 0, 0, 0, 0, 1, 0, 0), probesample(0, x, x, x, x, x, x, x))', 'probes: NaN')
    same('x = sqrt(0 - 1)\nprint(vgeo("Cube", x), lmsample("Cube", x, x, x, x))', 'vgeo, lmsample: NaN')


def s_random():
    print(f'-- {RUNS} random calls (seed {SEED}): each group runs cleanly --')
    rnd = random.Random(SEED)
    d = make_images() if not os.path.isdir(os.path.join(T, 'img')) else os.path.join(T, 'img')
    pre = f'i = image("{d}/rgba.png")\nj = image("{d}/sky.hdr")\nadd("sphere", "S", 1, 2, 3)\n' + SCENE

    def val():
        return rnd.choice(['0', '1', '2', '-1', '3', '7', '0.5', '-0.5', '1e9', '-1e9', '1e30', '"x"', 'nil', '"Cube"', 'i', 'j', '"S"', str(rnd.randrange(-20, 600)), str(rnd.uniform(-5, 5))])
    names = [n for n in SPECS if n not in ('render', 'render_frames', 'image', 'gpu')]
    batch = []
    for k in range(RUNS):
        nm = rnd.choice(names)
        n = SPECS[nm]
        lo, hi = (n, n) if isinstance(n, int) else n
        c = rnd.randint(lo, hi) if rnd.random() < 0.9 else rnd.randint(max(0, lo - 1), hi + 1)
        args = [val() for _ in range(c)]
        if nm in ('imgsize', 'imgpixel') and args and rnd.random() < 0.8:
            args[0] = rnd.choice(['i', 'j'])
        if nm in ('vgeo', 'lmsample') and args and rnd.random() < 0.8:
            args[0] = rnd.choice(['"Floor"', '"Roof"', '"Ball"', '"S"'])
        batch.append(f'print({nm}({", ".join(args)}))')
    # in groups: an error ends a run; then each line of a group that did not end cleanly alone
    g = 25
    for k in range(0, len(batch), g):
        lines = batch[k:k + g]
        ok, a = same(pre + '\n'.join(lines), f'random calls {k + 1}..{k + len(lines)}')
        if not ok:
            for ln in lines:
                if not clean(port(pre + ln)):
                    print('         first not clean:', ln)
                    break


def s_fuzz():
    print('-- random garbage into these builtins: no crash, no hang --')
    rnd = random.Random(SEED ^ 0x5eed)
    d = os.path.join(T, 'img') if os.path.isdir(os.path.join(T, 'img')) else make_images()
    files = [os.path.join(d, f) for f in os.listdir(d)]
    fz = os.path.join(T, 'fz')
    os.makedirs(fz, exist_ok=True)
    for k in range(max(RUNS // 5, 10)):
        # a damaged image: bytes of a good one flipped, cut, repeated
        src = rnd.choice([f for f in files if os.path.isfile(f)])
        b = bytearray(open(src, 'rb').read())
        for _ in range(rnd.randint(1, 8)):
            if b:
                b[rnd.randrange(len(b))] = rnd.randrange(256)
        if rnd.random() < 0.3:
            b = b[:rnd.randint(0, len(b))]
        if rnd.random() < 0.2:
            b = b[:33] + struct.pack('>II', rnd.choice([0, 1, 65535, 0x7fffffff, 0xffffffff]), rnd.choice([0, 1, 65535, 0x7fffffff])) + b[41:]
        p = os.path.join(fz, f'{k}' + os.path.splitext(src)[1])
        open(p, 'wb').write(bytes(b))
        code = f'i = image("{p}")\nprint(imgsize(i, 0), imgsize(i, 1), imgpixel(i, 0, 0, 0), imgpixel(i, imgsize(i, 0) - 1, imgsize(i, 1) - 1, 3))'
        r = port(code, timeout=120)
        ok = r[0] in (0, 1) and ('error: ' in r[1] or r[0] == 0)
        check(ok, f'damaged image {k} ({os.path.basename(src)}): {r[0]} {r[1].strip()[-60:]!r}')
    junk = ['vgeo', 'vgstat', 'probe', 'probeinfo', 'probesample', 'lightmap', 'lmsample', 'imgsize', 'imgpixel']
    for k in range(max(RUNS // 10, 5)):
        lines = []
        for _ in range(40):
            nm = rnd.choice(junk)
            args = [rnd.choice(['1e308', '-1e308', '0', '"' + 'x' * rnd.randint(0, 300) + '"', 'nil', str(rnd.uniform(-1e6, 1e6)), '"Cube"', 'sqrt(0-1)']) for _ in range(rnd.randint(0, 10))]
            lines.append(f'x = {nm}({", ".join(args)})')
        r = port('\n'.join(lines))
        check(r[0] in (0, 1), f'garbage run {k}: exit {r[0]}')


def main():
    print(f'bs_render: {BIN}, random runs {RUNS}, seed {SEED}')
    for nm, f in (('images', s_images), ('render', s_render), ('frames', s_frames), ('probes', s_probes), ('vgeo', s_vgeo), ('gpu', s_gpu),
                  ('args', s_args), ('random', s_random), ('fuzz', s_fuzz)):
        if want(nm):
            f()
    shutil.rmtree(T, True)
    print(f'... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
