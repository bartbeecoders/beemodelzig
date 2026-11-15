#!/usr/bin/env python3
"""Landscapes in and out (landio.zig):

  * heightmap import: 16-bit grey PNGs (as BeeModel exports them), 8-bit
    RGB / grey+alpha PNGs of other sizes (every filter type; resampled to
    2^k + 1), OpenEXR files (float as exported, half ZIP with R G B, half ZIPS
    with a Y channel, uint uncompressed): the Heightmap layer is base + value x
    height of the image's own samples (decoded here, resampled bilinearly
    here), the size a metre a sample unless given, the heights finite and in
    their range, the display mesh inside it; the file saved, opened and saved
    again gives the same LAND block;
  * export: the 16-bit PNG's samples are the heights over lowest..highest,
    rounded; the EXR's lines are the heights in metres; round trips (export,
    import, export: the same samples, the same EXR);
  * landscape.to_mesh (the display grid, every sample, painted: the vertex
    colours) through the .bee MESH / MVCL chunks; landscape.tiles (each tile
    its part of the heights and paint, centred where its part was; bad k);
  * damaged and garbage files (truncated, flipped bytes, random) refused or
    read as a sane landscape, no crash; undo and redo of import, to_mesh and
    tiles.

    python3 tests/landio.py BIN [damage-runs=20] [seed]

BEE_CPU (default 20) pins every run; LANDIO_ONLY=damaged,to_mesh,tiles,undo runs some
(export and import always).
"""
import os, random, struct, subprocess, sys, tempfile, zlib, shutil, atexit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '20')
ONLY = [x for x in os.environ.get('LANDIO_ONLY', '').split(',') if x]  # damaged,to_mesh,tiles,undo (export and import always run)


def want(sec):
    return not ONLY or sec in ONLY
FAILS = []
T = tempfile.mkdtemp(prefix='beelandio-', dir='/tmp')
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def port(steps, save=None, binary=None):
    a = []
    for s in steps:
        a += ['--op', s]
    if save:
        a += ['--op', f'file.save_as {save}']
    if os.path.exists(f'{T}/log.txt'):
        os.remove(f'{T}/log.txt')
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a], capture_output=True, text=True, errors='replace', timeout=600, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, f'the port hung: {steps[:4]}')
        return ''
    if r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'the port stopped ({r.returncode}): {steps[:4]}')
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def lands(p):
    """[(mesh index, block with its references and evaluation time zeroed)]"""
    if not os.path.exists(p):
        return []
    c = beefile.chunk(p, b'LAND') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, nb = struct.unpack_from('<II', c, o)
        b = bytearray(c[o + 8:o + 8 + nb])
        b[0:4] = b'\0' * 4
        b[72:76] = b'\0' * 4
        out.append((ix, bytes(b)))
        o += 8 + nb
    return out


def big_meshes(p, least=100):
    return [m for m in beefile.meshes(p) if len(m[0]) >= least] if os.path.exists(p) else []


def objs(p):
    """[(name, loc, rot, scale, mesh index)] from OBJS."""
    c = beefile.chunk(p, b'OBJS')
    n, = struct.unpack_from('<I', c)
    out = []
    for k in range(n):
        r = c[4 + k * 84:4 + k * 84 + 84]
        out.append((r[:32].split(b'\0')[0].decode(), struct.unpack_from('<9f', r, 32), struct.unpack_from('<I', r, 80)[0]))
    return out


def moved(src, dst, loc, scl):
    """The file again (version 1) with its landscape moved and scaled."""
    out = b'BEEM' + struct.pack('<I', 1)
    for t, c in beefile.chunks(src):
        if t == b'OBJS':
            c = bytearray(c)
            n, = struct.unpack_from('<I', c)
            for k in range(n):
                r = 4 + k * 84
                if c[r:r + 9] == b'Landscape':
                    struct.pack_into('<3f', c, r + 32, *loc)
                    struct.pack_into('<3f', c, r + 56, *scl)
            c = bytes(c)
        out += t + struct.pack('<I', len(c)) + c
    open(dst, 'wb').write(out)


def png_samples(path):
    """(w, h, depth, colour type, rows of samples) of a PNG (any filter); none
    there: (0, 0, 0, 0, [])."""
    if not os.path.exists(path):
        return 0, 0, 0, 0, []
    d = open(path, 'rb').read()
    w, h, depth, ct = struct.unpack('>IIBB', d[16:26])
    i, idat = 8, b''
    while i < len(d):
        n, = struct.unpack('>I', d[i:i + 4])
        if d[i + 4:i + 8] == b'IDAT':
            idat += d[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    bpp = depth // 8 * ch
    stride = w * bpp
    prev, rows, p = bytearray(stride), [], 0
    for _ in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                row[x] = (row[x] + a) & 255
            elif f == 2:
                row[x] = (row[x] + b) & 255
            elif f == 3:
                row[x] = (row[x] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(row))
        prev = row
    return w, h, depth, ct, rows


def make_png(path, w, h, ct, depth, pix, filters=(0, 1, 2, 3, 4)):
    """A PNG of these pixel bytes (rows of w * bpp), each row its own filter."""
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    bpp = depth // 8 * ch
    stride = w * bpp
    out, prev = b'', bytearray(stride)
    for y in range(h):
        row = pix[y * stride:(y + 1) * stride]
        f = filters[y % len(filters)]
        enc = bytearray(stride)
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 0:
                pr = 0
            elif f == 1:
                pr = a
            elif f == 2:
                pr = b
            elif f == 3:
                pr = (a + b) // 2
            else:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if pa <= pb and pa <= pc else b if pb <= pc else c
            enc[x] = (row[x] - pr) & 255
        out += bytes([f]) + bytes(enc)
        prev = bytearray(row)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    f = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, ct, 0, 0, 0))
    z = zlib.compress(out, 9)
    f += chunk(b'IDAT', z[:len(z) // 2]) + chunk(b'IDAT', z[len(z) // 2:]) + chunk(b'IEND', b'')
    open(path, 'wb').write(f)


def make_exr(path, w, h, chans, comp, values, y0=0):
    """A scanline EXR: chans [(name, type 0 uint 1 half 2 float)], comp 0 / 2 / 3,
    values[name] a w * h list."""
    lpb = 16 if comp == 3 else 1
    hdr = b'\x76\x2f\x31\x01\x02\x00\x00\x00'
    cl = b''.join(n.encode() + b'\0' + struct.pack('<iB3xii', t, 0, 1, 1) for n, t in chans) + b'\0'
    hdr += b'channels\0chlist\0' + struct.pack('<I', len(cl)) + cl
    hdr += b'compression\0compression\0' + struct.pack('<I', 1) + bytes([comp])
    hdr += b'dataWindow\0box2i\0' + struct.pack('<I', 16) + struct.pack('<4i', 0, y0, w - 1, y0 + h - 1)
    hdr += b'displayWindow\0box2i\0' + struct.pack('<I', 16) + struct.pack('<4i', 0, y0, w - 1, y0 + h - 1)
    hdr += b'lineOrder\0lineOrder\0' + struct.pack('<I', 1) + b'\0'
    hdr += b'pixelAspectRatio\0float\0' + struct.pack('<If', 4, 1.0)
    hdr += b'screenWindowCenter\0v2f\0' + struct.pack('<Iff', 8, 0, 0)
    hdr += b'screenWindowWidth\0float\0' + struct.pack('<If', 4, 1.0) + b'\0'
    nb = (h + lpb - 1) // lpb
    blocks = []
    for bi in range(nb):
        raw = b''
        for y in range(bi * lpb, min(h, bi * lpb + lpb)):
            for n, t in chans:
                fmt = {0: 'I', 1: 'e', 2: 'f'}[t]
                raw += struct.pack(f'<{w}{fmt}', *values[n][y * w:(y + 1) * w])
        data = raw
        if comp:
            half = (len(raw) + 1) // 2
            t = bytearray(len(raw))
            t[:half] = raw[0::2]
            t[half:] = raw[1::2]
            d = bytearray(len(t))
            for i in range(len(t)):
                d[i] = t[i] if i == 0 else (t[i] - t[i - 1] + 128) & 255
            z = zlib.compress(bytes(d), 6)
            if len(z) < len(raw):
                data = z
        blocks.append(struct.pack('<iI', y0 + bi * lpb, len(data)) + data)
    off = len(hdr) + 8 * nb
    table = b''
    for b in blocks:
        table += struct.pack('<Q', off)
        off += len(b)
    open(path, 'wb').write(hdr + table + b''.join(blocks))


def raw_lands(p):
    """[raw LAND blocks] as saved (header, then the arrays)."""
    if not os.path.exists(p):
        return []
    c = beefile.chunk(p, b'LAND') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        _, nb = struct.unpack_from('<II', c, o)
        out.append(c[o + 8:o + 8 + nb])
        o += 8 + nb
    return out


def head(b):
    """The block's header (landscape.zig Header) as a dict."""
    n, size, nl, ver, disp = struct.unpack_from('<IfIII', b, 4)
    _, hoff, coff, soff = struct.unpack_from('<QQQQ', b, 24)
    np_, hmin, hmax = struct.unpack_from('<Iff', b, 60)
    typ0, = struct.unpack_from('<I', b, 128)
    data0, = struct.unpack_from('<Q', b, 128 + 56)
    return dict(n=n, size=size, nl=nl, disp=disp, h=hoff, splat=soff, np=np_, hmin=hmin, hmax=hmax, typ0=typ0, data0=data0)


def arr(b, off, n):
    return struct.unpack_from(f'<{n * n}f', b, off) if off and off + n * n * 4 <= len(b) else ()


def finite(v):
    return all(x == x and abs(x) != float('inf') for x in v)


def close(a, b, rel=1e-4):
    return abs(a - b) <= rel * max(1.0, abs(b))


def side_for(w, h):
    """2^k + 1 >= the longer side (at least 65, at most 4097)."""
    s, c = max(w, h), 65
    while c < s and c < 4097:
        c = c * 2 - 1
    return c


def resample(v, w, h, n):
    """Bilinear, w x h stretched onto n x n (corners on corners)."""
    if w == n and h == n:
        return list(v)
    out = []
    for j in range(n):
        z = j * (h - 1) / (n - 1)
        iz = min(int(z), max(h - 2, 0))
        fz = z - iz
        for i in range(n):
            x = i * (w - 1) / (n - 1)
            ix = min(int(x), max(w - 2, 0))
            fx = x - ix
            k = iz * w + ix
            cs, rs = (1 if w > 1 else 0), (w if h > 1 else 0)
            h0 = (v[k + cs] - v[k]) * fx + v[k]
            h2 = (v[k + rs + cs] - v[k + rs]) * fx + v[k + rs]
            out.append((h2 - h0) * fz + h0)
    return out


def png_values(path):
    """(w, h, the first channel 0..1)."""
    w, h, depth, ct, rows = png_samples(path)
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    out = []
    for r in rows:
        for x in range(w):
            if depth == 16:
                out.append(((r[x * 2 * ch] << 8) | r[x * 2 * ch + 1]) / 65535)
            else:
                out.append(r[x * ch] / 255)
    return w, h, out


def exr_lines(path):
    """An uncompressed float EXR (as exported): [(y, line bytes)]."""
    d = open(path, 'rb').read()
    o, comp, win = 8, None, None
    while d[o] != 0:
        e = d.index(b'\0', o)
        name = d[o:e]
        t = d.index(b'\0', e + 1)
        sz, = struct.unpack_from('<I', d, t + 1)
        v = d[t + 5:t + 5 + sz]
        if name == b'compression':
            comp = v[0]
        elif name == b'dataWindow':
            win = struct.unpack('<4i', v)
        o = t + 5 + sz
    o += 1
    nlines = win[3] - win[1] + 1
    offs = struct.unpack_from(f'<{nlines}Q', d, o)
    out = []
    for f in offs:
        y, n = struct.unpack_from('<iI', d, f)
        out.append((y, d[f + 8:f + 8 + n]))
    return comp, win, out


def imported(name, path, args, w, h, vals, png):
    """BeeModel imports it: one landscape, its Heightmap layer base + value x
    height of the image (resampled), a sane block and display mesh, and the
    file reads back to the same block."""
    p, p2 = f'{T}/p.bee', f'{T}/p2.bee'
    for f in (p, p2):
        if os.path.exists(f):
            os.remove(f)
    log = port([f'landscape.import {path} {args}'.strip()], save=p)
    bl = raw_lands(p)
    check(len(bl) == 1, f'{name}: one LAND block ({len(bl)})')
    if len(bl) != 1:
        return None
    b = bl[0]
    hd = head(b)
    n = hd['n']
    check(n == side_for(w, h), f'{name}: {n} samples a side (2^k + 1, the longer side {max(w, h)})')
    check(f'imported a heightmap: {n} x {n}' in log, f'{name}: it says "imported a heightmap: {n} x {n}"')
    kw = dict(zip(args.split()[0::2], map(float, args.split()[1::2])))
    H = kw.get('height', 100.0 if png else 1.0)
    B = kw.get('base', 0.0)
    S = kw.get('size', float(n - 1))
    check(close(hd['size'], S), f'{name}: the size {hd["size"]:g} (want {S:g})')
    lay = arr(b, hd['data0'], n)
    exp_h = [x * H + B for x in resample(vals, w, h, n)]
    bad = sum(1 for x, y in zip(lay, exp_h) if not close(x, y))
    check(hd['typ0'] == 6 and len(lay) == n * n and bad == 0,
          f'{name}: the Heightmap layer is base + value x height ({bad} of {len(exp_h)} samples off)')
    hs = arr(b, hd['h'], n)
    check(len(hs) == n * n and finite(hs) and close(hd['hmin'], min(hs)) and close(hd['hmax'], max(hs)),
          f'{name}: the heights finite, lowest {hd["hmin"]:g} and highest {hd["hmax"]:g} as the samples')
    ms = big_meshes(p)
    ys = [v[1] for v in ms[0][0]] if len(ms) == 1 else []
    xs = [v[0] for v in ms[0][0]] if len(ms) == 1 else []
    eps = 1e-3 * max(1.0, abs(hd['hmin']), abs(hd['hmax']))
    check(ys and finite(ys) and min(ys) >= hd['hmin'] - eps and max(ys) <= hd['hmax'] + eps and close(max(xs) - min(xs), hd['size'], 1e-3),
          f'{name}: the display mesh ({len(ys)} vertices) inside the heights, as wide as the size')
    port([f'file.open {p}'], save=p2)
    check(lands(p2) == lands(p), f'{name}: saved, opened and saved: the same LAND block')
    return b


def grid_part(src, n, k, ax, az, per=1, sz=4):
    """The tile (ax, az) of k x k: its rows of a source array (per values a sample of sz bytes)."""
    ts = (n - 1) // k + 1
    out = []
    for r in range(ts):
        s = ((az * (ts - 1) + r) * n + ax * (ts - 1)) * per
        out.extend(src[s:s + ts * per])
    return out


# the user's own settings must not move while this runs (read only: mtime and size)
import pwd
REAL = pwd.getpwuid(os.getuid()).pw_dir


def real_state():
    out = {}
    for d in (f'{REAL}/.config/beemodel', f'{REAL}/.config/beemodel-zig'):
        if os.path.isdir(d):
            for n in sorted(os.listdir(d)):
                st = os.stat(os.path.join(d, n))
                out[os.path.join(d, n)] = (st.st_mtime_ns, st.st_size)
    return out


REAL0 = real_state()
rnd = random.Random(SEED)
print(f'landio: seed {SEED}')

tl = ['landscape.add mountains res 257 size 120 seed 5', 'landscape.paint add snow', 'landscape.brush snow 10 10 radius 30 strength 1', 'landscape.set detail 129']

# ---- export: PNG samples, EXR lines -----------------------------------------------------
print('== export')
base = 'landscape.add hills res 129 size 60 seed 3'
log = port([base, f'landscape.export {T}/p.png', f'landscape.export {T}/p.exr'], save=f'{T}/e.bee')
sp = png_samples(f'{T}/p.png')
check(sp[:4] == (129, 129, 16, 0), f'a 16-bit grey PNG, 129 x 129 ({sp[:4]})')
eb = raw_lands(f'{T}/e.bee')
check(len(eb) == 1, 'the landscape saved alongside')
if eb and sp[4]:
    hd = head(eb[0])
    hs = arr(eb[0], hd['h'], 129)
    rg = max(hd['hmax'] - hd['hmin'], 1e-12)
    got = [v for r in sp[4] for v in struct.unpack('>129H', r)]
    exp_ = [min(65535, max(0, int((x - hd['hmin']) / rg * 65535 + 0.5))) for x in hs]
    exact = sum(1 for g, w_ in zip(got, exp_) if g == w_)
    near = all(abs(g - w_) <= 1 for g, w_ in zip(got, exp_))
    check(near and exact >= 0.99 * len(exp_), f'its samples are the heights over lowest..highest, rounded ({exact} of {len(exp_)} exact)')
    check(len(set(got)) > 50 and min(got) == 0 and max(got) == 65535, 'the samples span 0..65535 (lowest..highest)')
    ok = os.path.exists(f'{T}/p.exr')
    if ok:
        comp, win, lines = exr_lines(f'{T}/p.exr')
        ok = comp == 0 and win == (0, 0, 128, 128) and len(lines) == 129 and all(
            y == k and len(ln) == 129 * 4 and struct.unpack('<129f', ln) == hs[k * 129:(k + 1) * 129] for k, (y, ln) in enumerate(lines))
    check(ok, 'the EXR: 129 uncompressed lines of the heights in metres')
check(f'exported {T}/p.png' in log and f'exported {T}/p.exr' in log, 'it says "exported <file>"')

# ---- import what was exported, round trips ---------------------------------------------
print('== import')
pw, ph, pv = png_values(f'{T}/p.png')
imported('its 16-bit PNG (size, height, base)', f'{T}/p.png', 'size 60 height 25 base -4', pw, ph, pv, True)
imported('its 16-bit PNG', f'{T}/p.png', '', pw, ph, pv, True)
if eb:
    hd = head(eb[0])
    imported('its float EXR', f'{T}/p.exr', 'height 2 base 1', 129, 129, list(arr(eb[0], hd['h'], 129)), False)
port([f'landscape.import {T}/p.png', f'landscape.export {T}/p2.png'])
check(png_samples(f'{T}/p2.png')[4] == sp[4], 'export, import, export: the same samples')
port([f'landscape.import {T}/p.exr', f'landscape.export {T}/p3.exr'])
check(os.path.exists(f'{T}/p3.exr') and open(f'{T}/p3.exr', 'rb').read() == open(f'{T}/p.exr', 'rb').read(), 'an EXR imported and exported: the same file')

# other PNGs: 8-bit RGB (all filters), grey + alpha, RGBA 16-bit; other sizes
w, h = 100, 70
pix = bytes(rnd.randrange(256) for _ in range(w * h * 3))
make_png(f'{T}/rgb.png', w, h, 2, 8, pix)
imported('an 8-bit RGB PNG 100 x 70 (every filter)', f'{T}/rgb.png', 'size 50 height 20 base -3', w, h, [pix[i * 3] / 255 for i in range(w * h)], True)
pix = bytes(rnd.randrange(256) for _ in range(40 * 300 * 2))
make_png(f'{T}/ga.png', 40, 300, 4, 8, pix, filters=(4, 3, 1))
imported('an 8-bit grey + alpha PNG 40 x 300', f'{T}/ga.png', '', 40, 300, [pix[i * 2] / 255 for i in range(40 * 300)], True)
pix = bytes(rnd.randrange(256) for _ in range(65 * 65 * 8))
make_png(f'{T}/rgba16.png', 65, 65, 6, 16, pix, filters=(2, 4))
imported('a 16-bit RGBA PNG 65 x 65 (no resampling)', f'{T}/rgba16.png', 'height 10', 65, 65,
         [((pix[i * 8] << 8) | pix[i * 8 + 1]) / 65535 for i in range(65 * 65)], True)
make_png(f'{T}/one.png', 1, 1, 0, 8, b'\x80')
imported('a 1 x 1 PNG', f'{T}/one.png', '', 1, 1, [0x80 / 255], True)


def half(v):
    return [struct.unpack('<e', struct.pack('<e', x))[0] for x in v]


# EXRs
vw, vh = 90, 50
vr = [rnd.uniform(-3, 9) for _ in range(vw * vh)]
make_exr(f'{T}/rgb_zip.exr', vw, vh, [('B', 1), ('G', 1), ('R', 1)], 3, {'R': vr, 'G': [0.0] * len(vr), 'B': [5.0] * len(vr)})
imported('a half ZIP EXR (B G R: R taken)', f'{T}/rgb_zip.exr', 'height 3', vw, vh, half(vr), False)
vs = [rnd.choice((1, -1)) * rnd.uniform(0, 1.2e-4) for _ in range(vw * vh)]
make_exr(f'{T}/sub.exr', vw, vh, [('Y', 1)], 3, {'Y': vs})
imported('a half ZIP EXR of tiny values (subnormal halves)', f'{T}/sub.exr', 'height 100000', vw, vh, half(vs), False)
make_exr(f'{T}/y_zips.exr', vw, vh, [('A', 2), ('Y', 1), ('R', 2)], 2, {'Y': vr, 'R': [9.0] * len(vr), 'A': [1.0] * len(vr)}, y0=-7)
imported('a half ZIPS EXR (A Y R: Y taken; the window from -7)', f'{T}/y_zips.exr', '', vw, vh, half(vr), False)
vu = [rnd.randrange(1 << 20) for _ in range(33 * 129)]
make_exr(f'{T}/u.exr', 33, 129, [('Z', 0)], 0, {'Z': vu})
imported('a uint EXR, no compression (the first channel)', f'{T}/u.exr', 'height 0.0001', 33, 129, [float(x) for x in vu], False)
vf = [rnd.uniform(-50, 50) for _ in range(129 * 129)]
make_exr(f'{T}/f_zip.exr', 129, 129, [('Y', 2)], 3, {'Y': vf})
imported('a float ZIP EXR 129 x 129', f'{T}/f_zip.exr', '', 129, 129, [struct.unpack('<f', struct.pack('<f', x))[0] for x in vf], False)

if want('damaged'):
    # ---- damaged files ----------------------------------------------------------------------
    print('== damaged')
    srcs = [f'{T}/p.png', f'{T}/rgb.png', f'{T}/rgb_zip.exr', f'{T}/p.exr', f'{T}/y_zips.exr']
    nd = sane = loaded = 0
    for k in range(RUNS):
        src = open(rnd.choice(srcs), 'rb').read()
        kind = rnd.randrange(3)
        if kind == 0:
            d = src[:rnd.randrange(1, len(src))]
        elif kind == 1:
            d = bytearray(src)
            for _ in range(rnd.randrange(1, 8)):
                d[rnd.randrange(len(d))] = rnd.randrange(256)
            d = bytes(d)
        else:
            d = src[:8] + bytes(rnd.randrange(256) for _ in range(rnd.randrange(200)))
        open(f'{T}/bad.bin', 'wb').write(d)
        p = f'{T}/p.bee'
        if os.path.exists(p):
            os.remove(p)
        log = port([f'landscape.import {T}/bad.bin'], save=p)
        bl = raw_lands(p)
        nd += 1
        loaded += 1 if bl else 0
        ok = False
        if not bl:
            ok = 'cannot read' in log
        elif len(bl) == 1:
            hd = head(bl[0])
            hs = arr(bl[0], hd['h'], hd['n'])
            ok = hd['n'] >= 65 and len(hs) == hd['n'] ** 2 and finite(hs) and f'imported a heightmap: {hd["n"]} x {hd["n"]}' in log
        if ok:
            sane += 1
        else:
            print(f'    case {k} (kind {kind}, {len(d)} bytes): {len(bl)} blocks, said "cannot read": {"cannot read" in log}')
            if os.environ.get('LANDIO_KEEP'):
                shutil.copy(f'{T}/bad.bin', os.path.join(os.environ['LANDIO_KEEP'], f'bad{k}.bin'))
    check(sane == nd, f'{sane} / {nd} damaged files: refused ("cannot read") or read as one sane landscape ({loaded} still read), no crash')
    make_exr(f'{T}/far.exr', 20, 20, [('Y', 2)], 0, {'Y': [1.0] * 400})
    d = bytearray(open(f'{T}/far.exr', 'rb').read())
    first, = struct.unpack_from('<Q', d, len(d) - 20 * 88 - 160)
    struct.pack_into('<i', d, first, 1000)
    open(f'{T}/far.exr', 'wb').write(d)
    log = port([f'landscape.import {T}/far.exr'], save=f'{T}/p.bee')
    check(len(lands(f'{T}/p.bee')) == 1, 'an EXR block whose lines lie outside its window: left out, no crash')
    log = port([f'landscape.import {T}/nothere.png'])
    check(f'landscape.import: cannot read (a PNG or an OpenEXR heightmap): {T}/nothere.png' in log, 'a missing file: it says it cannot read it')
    log = port(['landscape.import'])
    check('landscape: not understood: ' in log, 'no file: "not understood"')
    log = port([f'landscape.import {T}/p.png size 3 wobble 2'])
    check('landscape: not understood: ' in log, 'an unknown word: "not understood"')

if want('to_mesh'):
    # ---- to_mesh -----------------------------------------------------------------------------
    print('== to_mesh')
    paint = [base, 'landscape.paint add grass', 'landscape.paint add rock', 'landscape.paint auto']
    port(paint, save=f'{T}/pre.bee')
    pre = raw_lands(f'{T}/pre.bee')
    for args in ('', 'full'):
        p = f'{T}/p.bee'
        port(paint + [f'landscape.to_mesh {args}'.strip()], save=p)
        mp = big_meshes(p)
        tag = args or '(display)'
        check(lands(p) == [] and len(mp) == 1, f'to_mesh {tag}: one plain mesh (no LAND)')
        if len(mp) != 1 or len(pre) != 1:
            continue
        vs_, polys = mp[0]
        hd = head(pre[0])
        ys = [v[1] for v in vs_]
        check(finite([c for v in vs_ for c in v]) and min(ys) >= hd['hmin'] - 1e-3 and max(ys) <= hd['hmax'] + 1e-3
              and all(len(q) >= 3 and max(q) < len(vs_) for q in polys), f'to_mesh {tag}: {len(vs_)} vertices inside the heights, {len(polys)} polygons on them')
        if args == 'full':
            hs = arr(pre[0], hd['h'], 129)
            xs = sorted(set(round(v[0], 3) for v in vs_))
            zs = sorted(set(round(v[2], 3) for v in vs_))
            check(len(vs_) == 129 * 129 and len(xs) == 129 and len(zs) == 129 and len(set((round(v[0], 3), round(v[2], 3)) for v in vs_)) == 129 * 129,
                  f'to_mesh full: every sample a vertex of a 129 x 129 grid ({len(xs)} x {len(zs)})')
            byxz = {(round(v[0], 3), round(v[2], 3)): v[1] for v in vs_}
            off = sum(1 for r in range(129) for c in range(129) if not close(byxz.get((xs[c], zs[r]), 1e30), hs[r * 129 + c]))
            check(off == 0, f'to_mesh full: each vertex at its sample\'s height ({off} off)')
        vp = beefile.chunk(p, b'MVCL')
        check(vp is not None and len(vp) > len(vs_) * 4 and len(set(vp[4:])) > 2, f'to_mesh {tag}: the vertex colours there ({len(vp) if vp else 0} bytes)')
    log = port(['landscape.add hills res 4097', 'landscape.to_mesh full'], save=f'{T}/p.bee')
    check('landscape.to_mesh full: 2049 samples a side at most' in log and len(lands(f'{T}/p.bee')) == 1, '4097 a side: to_mesh full says no, the landscape stays')

if want('tiles'):
    # ---- tiles -------------------------------------------------------------------------------
    print('== tiles')
    p = f'{T}/p.bee'
    port(tl, save=f'{T}/t0.bee')
    moved(f'{T}/t0.bee', f'{T}/t1.bee', (3, 1, -2), (2, 1.5, 0.5))
    log = port([f'file.open {T}/t1.bee', 'landscape.tiles 2'], save=p)
    src = raw_lands(f'{T}/t1.bee')
    lp = raw_lands(p)
    check(len(src) == 1 and len(lp) == 4, f'four tiles ({len(lp)})')
    if len(src) == 1 and len(lp) == 4:
        sh = head(src[0])
        n = sh['n']
        shs = arr(src[0], sh['h'], n)
        ssp = src[0][sh['splat']:sh['splat'] + n * n * 8] if sh['splat'] else b''
        parts = {(ax, az): (grid_part(shs, n, 2, ax, az), grid_part(ssp, n, 2, ax, az, 8)) for ax in range(2) for az in range(2)}
        found, meta = set(), True
        for b in lp:
            hd = head(b)
            lay = arr(b, hd['data0'], hd['n'])
            sp_ = b[hd['splat']:hd['splat'] + hd['n'] ** 2 * 8] if hd['splat'] else b''
            for key, (hpart, spart) in parts.items():
                if len(lay) == len(hpart) and all(close(x, y) for x, y in zip(lay, hpart)):
                    found.add(key)
                    meta = meta and bytes(spart) == sp_
            meta = meta and hd['n'] == (n - 1) // 2 + 1 and close(hd['size'], sh['size'] / 2) and hd['disp'] == sh['disp'] and hd['np'] == sh['np'] and hd['typ0'] == 6
        check(len(found) == 4, f'each tile holds its quarter of the heights ({len(found)} of 4 found)')
        check(meta and sh['splat'] != 0, 'each tile: half the size, the display detail, the paint layers and its quarter of the paint')
    ts = [(n_, l) for n_, l, _ in objs(p) if n_.startswith('Landscape')]
    locs = [l[:3] for _, l in ts]
    mean = [sum(c[i] for c in locs) / max(1, len(locs)) for i in range(3)]
    check(len(ts) == 4 and len(set(n_ for n_, _ in ts)) == 4 and len(set(locs)) == 4, f'four tiles, four names, four places ({[x[0] for x in ts]})')
    check(len(ts) == 4 and all(close(a_, b_) for a_, b_ in zip(mean, (3, 1, -2))) and all(l[6:9] == (2, 1.5, 0.5) for _, l in ts),
          f'the tiles centred where the landscape was, its scale kept (mean {[round(x, 3) for x in mean]})')
    check('landscape split into tiles: 4' in log, 'it says "landscape split into tiles: 4"')
    for k in ('3', '1', '8', 'x'):
        log = port(tl[:1] + [f'landscape.tiles {k}'], save=p)
        check(len(lands(p)) == 1 and 'k divides the samples a side less 1' in log, f'tiles {k} on 257: refused')

if want('undo'):
    # ---- undo / redo -------------------------------------------------------------------------
    print('== undo')
    p = f'{T}/p.bee'
    port([f'landscape.import {T}/rgb.png', 'edit.undo'], save=p)
    check(lands(p) == [], 'import undone: no landscape')
    port([f'landscape.import {T}/rgb.png', 'edit.undo', 'edit.redo'], save=p)
    same = lands(p)
    port([f'landscape.import {T}/rgb.png'], save=f'{T}/q.bee')
    check(len(same) == 1 and same == lands(f'{T}/q.bee'), 'import redone: the same block')
    port([base, 'landscape.to_mesh full', 'edit.undo'], save=p)
    check(len(lands(p)) == 1 and len(big_meshes(p)) == 1, 'to_mesh undone: the landscape again')
    port([base, 'landscape.to_mesh full', 'edit.undo', 'edit.redo'], save=p)
    check(lands(p) == [] and len(big_meshes(p)) == 1, 'to_mesh redone: the plain mesh')
    port(tl[:1] + ['landscape.tiles 2', 'edit.undo'], save=p)
    check(len(lands(p)) == 1, 'tiles undone: one landscape')
    port(tl[:1] + ['landscape.tiles 2', 'edit.undo', 'edit.redo'], save=p)
    check(len(lands(p)) == 4, 'tiles redone: four')

    # a file of tiles, opened and saved: the same blocks
    port(tl + ['landscape.tiles 2'], save=f'{T}/o.bee')
    port([f'file.open {T}/o.bee'], save=p)
    check(lands(f'{T}/o.bee') == lands(p) and len(lands(p)) == 4, 'a file of tiles opened and saved: the same blocks')

moved_ = [k for k in set(REAL0) | set(real_state()) if REAL0.get(k) != real_state().get(k)]
check(not moved_, f'the user\'s ~/.config/beemodel and beemodel-zig untouched {moved_}')
print(f'landio: seed {SEED} fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
