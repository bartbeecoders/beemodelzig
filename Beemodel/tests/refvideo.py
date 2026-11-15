#!/usr/bin/env python3
"""Reference images and animation output.

    BEEMODEL_BIN=zig-out-debug/bin/beemodel python3 tests/refvideo.py [workdir] [set fuzz video esc]

  - a plan set: every page sorted out as it should be (the report's lines);
    the .bee read back (13 objects, the folders, the hidden copy, the levels);
    save, open, save gives the same objects and folders; pin and kind move
    and re-sort the pages; one undo takes the import back;
  - PDFs truncated and with bits flipped (a fixed seed), damaged .bee chunks:
    no crash, no hang;
  - frames, .png, .apng, ffmpeg's kinds, a failing ffmpeg, no ffmpeg; the
    saved scene opened again renders the same frames;
  - Esc in a real window (tests/wl_fake.py, a fake compositor): the frames
    done are kept, the APNG says how many there are.
"""
import os, random, shutil, struct, subprocess, sys, tempfile, time, zlib
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

BIN = os.path.abspath(os.environ.get('BEEMODEL_BIN', 'zig-out-debug/bin/beemodel'))
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# headless runs write only under /tmp
WORK = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix='bee-refvideo-', dir='/tmp')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*args, env=None, timeout=300):
    """A headless run: (exit code, the console's lines)."""
    log = os.path.join(WORK, 'port.log')
    if os.path.exists(log):
        os.remove(log)
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([BIN, '--shot', os.path.join(WORK, 'port.ppm'), '--dump-log', log, *args],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=e, timeout=timeout)
    lines = open(log, errors='replace').read().split('\n') if os.path.exists(log) else []
    return p.returncode, lines, p.stderr.decode(errors='replace')


def cmds(*c):
    out = []
    for x in c:
        out += ['--key', 'enter', '--type', x, '--key', 'enter']
    return out


# ---- .bee chunks ---------------------------------------------------------------
def chunks(path):
    d = open(path, 'rb').read()
    o, out = 8, {}
    while o + 8 <= len(d):
        t = d[o:o + 4]
        s = struct.unpack('<I', d[o + 4:o + 8])[0]
        b = d[o + 8:o + 8 + s]
        if t == b'ZCHK':
            t, b = b[:4], zlib.decompress(b[8:], -15)
        out.setdefault(t, []).append(b)
        o += 8 + s
    return out


def objects(path):
    c = chunks(path)
    o = c[b'OBJS'][0]
    n = struct.unpack('<I', o[:4])[0]
    res = {}
    for k in range(n):
        r = o[4 + k * 84:4 + (k + 1) * 84]
        name = r[:32].split(b'\0')[0].decode()
        v = struct.unpack('<9f', r[32:68])
        res[name] = dict(loc=v[:3], rot=v[3:6], scl=v[6:9], flags=struct.unpack('<I', r[76:80])[0], index=k)
    return res


def folders(path):
    """object name -> folder name, from FOLD."""
    c = chunks(path)
    d = c[b'FOLD'][0]
    n = struct.unpack('<I', d[:4])[0]
    recs = {}
    for k in range(n):
        r = d[4 + k * 48:4 + (k + 1) * 48]
        recs[struct.unpack('<I', r[:4])[0]] = (r[16:48].split(b'\0')[0].decode(), struct.unpack('<3I', r[4:16]))
    o = 4 + n * 48
    m = struct.unpack('<I', d[o:o + 4])[0]
    uids = struct.unpack('<%dI' % (len(c[b'UIDS'][0]) // 4), c[b'UIDS'][0])
    names = {v['index']: k for k, v in objects(path).items()}
    out = {}
    for k in range(m):
        u, f = struct.unpack('<2I', d[o + 4 + k * 8:o + 12 + k * 8])
        out[names[uids[1:].index(u)]] = recs[f][0]
    return out, recs


# ---- a plan set ---------------------------------------------------------------------
def pdf(path, pages):
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', None,
            b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>']
    kids = []
    for w, h, texts, lines in pages:
        ops = [b'0.6 w']
        for x0, y0, x1, y1 in lines:
            ops.append(b'%g %g m %g %g l S' % (x0, y0, x1, y1))
        for x, y, size, t in texts:
            t = t.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
            ops.append(b'BT /F1 %g Tf %g %g Td (' % (size, x, y) + t.encode('cp1252') + b') Tj ET')
        body = b'\n'.join(ops)
        objs.append(b'<< /Length %d >>\nstream\n' % len(body) + body + b'\nendstream')
        content = len(objs)
        objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %g %g] /Contents %d 0 R '
                    b'/Resources << /Font << /F1 3 0 R >> >> >>' % (w, h, content))
        kids.append(len(objs))
    objs[1] = b'<< /Type /Pages /Kids [%s] /Count %d >>' % (b' '.join(b'%d 0 R' % k for k in kids), len(kids))
    out = bytearray(b'%PDF-1.4\n')
    offs = []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += b'%d 0 obj\n' % (i + 1) + o + b'\nendobj\n'
    x = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for o in offs:
        out += b'%010d 00000 n \n' % o
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, x)
    open(path, 'wb').write(out)


A4L = (842, 595)


def sheet(title, scale, extra=()):
    texts = [(30, 40, 9, 'Bouwheer: Peeters'), (30, 28, 9, title)]
    if scale:
        texts.append((400, 28, 9, 'schaal: ' + scale))
    texts += list(extra)
    lines = [(100, 120, 700, 120), (150, 120, 150, 400), (650, 120, 650, 400), (150, 400, 650, 400)]
    return (A4L[0], A4L[1], texts, lines)


def png(path, w, h, px=None):
    raw = b''.join(b'\0' + b''.join(bytes(px(x, y) if px else (200, 120, 60)) for x in range(w)) for y in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def make_set(d):
    os.makedirs(d)
    pdf(os.path.join(d, 'Huis_G_N_01_voorgevel.pdf'), [sheet('G_N Voorgevel', '1:50')])
    pdf(os.path.join(d, 'Huis_G_B_01_voorgevel.pdf'), [sheet('G_B Voorgevel', '1:50')])
    pdf(os.path.join(d, 'Huis_G_N_02_gevel rechts.pdf'), [sheet('G_N Gevel rechts', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_00_plan gelijkvloers.pdf'), [sheet('P_N Plan gelijkvloers', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_01_plan verdieping.pdf'), [sheet('P_N Plan verdieping', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_-1_plan kelder.pdf'), [sheet('P_N Plan kelder', '1:50')])
    pdf(os.path.join(d, 'Huis_L_legende.pdf'), [sheet('Legende', None)])
    pdf(os.path.join(d, 'Dossier.pdf'), [sheet('S_N Doorsnede A-A', '1:100'),
                                         sheet('G_N Achtergevel', '1:100'),
                                         sheet('I_N Inplantingsplan', None)])
    png(os.path.join(d, 'foto straatzijde.png'), 400, 300)
    open(os.path.join(d, 'notes.txt'), 'w').write('not a drawing\n')


HOME_REFS = '/tmp/beemodel-headless/BeeModel/References'


US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51}
US_SHIFT = {'_': 12}


def fake_wl(binary, home):
    """The fake compositor (tests/wl_fake.py) running a binary."""
    import wl_fake
    f = wl_fake.Fake(binary, size=(1280, 800), env={'HOME': home, 'XDG_CACHE_HOME': os.path.join(home, 'cache')})
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None, 20)
    f.enter(600, 300)
    f.motion(600, 300)
    f.pump(0.3)
    return f


def typ(f, text):
    for ch in text:
        if ch in US_SHIFT or ch.isupper():
            f.key(US_SHIFT[ch] if ch in US_SHIFT else US[ch.lower()], 1)
        else:
            f.key(US[ch])


def test_set():
    print('-- a folder of drawings --')
    src = os.path.join(WORK, 'Plannen', 'WoningPeeters')
    shutil.rmtree(src, ignore_errors=True)
    make_set(src)
    shutil.rmtree(os.path.join(HOME_REFS, 'WoningPeeters'), ignore_errors=True)
    bee = os.path.join(WORK, 'set.bee')
    t0 = time.time()
    rc, log, err = port(*cmds('object.add_references ' + src, 'file.save ' + bee))
    took = time.time() - t0
    rep = [ln for ln in log if ln.startswith('  references') or ln.startswith('    ')]
    check(rc == 0, f'the import runs ({took:.1f} s) {err[-200:]}')
    want = ['front      voorgevel 1:50, shown',
            'front      voorgevel 1:50, existing, hidden',
            'right      gevel rechts 1:50, shown',
            'plan       plan gelijkvloers level 0 1:50, shown',
            'plan       plan verdieping level 1 1:50, hidden',
            'plan       plan kelder level -1 1:50, hidden',
            'legend     legende (a legend: left out)',
            'section    doorsnede a-a p1 1:100, hidden',
            'back       achtergevel p2 1:100, shown',
            'site       inplantingsplan p3 1:100 (from other pages), hidden',
            'other      foto straatzijde no scale: 10 m wide, hidden']
    text = '\n'.join(rep)
    missing = [w for w in want if w not in text]
    check(not missing, f'every page sorted out as it should be {missing}')
    check('references: 10 pages from 9 files into the folder Refs WoningPeeters' in text, '10 pages from 9 files')

    # the file read back: 13 objects, the folders, the hidden copy, the levels
    po = objects(bee)
    fp, rp = folders(bee)
    hidden = lambda o: bool(o['flags'] & 0x200)
    check(len(po) == 13 and fp.get('Ref voorgevel') == 'Elevations' and 'Ref voorgevel B' in po and hidden(po['Ref voorgevel B'])
          and abs(po.get('Ref plan verdieping', {'loc': (0, 0, 0)})['loc'][1] - 3) < 1e-4,
          f'the file: {len(po)} objects, Ref voorgevel in {fp.get("Ref voorgevel")}, its copy hidden, the upper floor at 3 m')
    check(all(abs(v) < 1e5 and v == v for o in po.values() for f in ('loc', 'rot', 'scl') for v in o[f]), 'places, turns and sizes finite')
    bee_re = bee + '.re.bee'
    rc, log, _ = port(*cmds('file.open ' + bee, 'file.save ' + bee_re))
    pr = objects(bee_re)
    check(rc == 0 and {k: (v['loc'], v['rot'], v['scl'], v['flags'] & ~1) for k, v in pr.items()} == {k: (v['loc'], v['rot'], v['scl'], v['flags'] & ~1) for k, v in po.items()}
          and folders(bee_re) == (fp, rp), 'save, open, save: the same objects and folders')

    d = os.path.join(HOME_REFS, 'WoningPeeters')
    pngs = sorted(n for n in os.listdir(d) if n.endswith('.png'))
    check('Dossier-p3.png' in pngs and len(pngs) == 10, f'the pages drawn ({len(pngs)} PNGs)')
    t = os.path.getmtime(os.path.join(d, 'Huis_G_N_01_voorgevel.png'))
    rc, log, _ = port(*cmds('object.add_references ' + src, 'object.add_references ' + src, 'console.list'))
    check(os.path.getmtime(os.path.join(d, 'Huis_G_N_01_voorgevel.png')) == t, 'a page drawn is not drawn again')
    check(any('Refs WoningPeeters.001' in ln for ln in log), 'a second import: a folder of its own')
    # undo in one step
    rc, log, err = port(*cmds('object.add_references ' + src, 'file.save ' + bee),
                        '--key', 'esc', '--move', '615,360', '--key', 'ctrl+z', *cmds('file.save ' + bee + '2'))
    check(len(objects(bee)) == 13 and len(objects(bee + '2')) == 3 and not folders(bee + '2')[1],
          f'one undo step takes it back ({len(objects(bee))} then {len(objects(bee + "2"))})')

    # pin and kind: the pages move and are sorted again; the file reads back
    rc, log, _ = port(*cmds('object.add_references ' + src, 'object.reference_pin Ref voorgevel 100 200 1 2 3',
                            'object.reference_kind Ref foto straatzijde plan 2 30', 'object.reference_kind Ref plan verdieping left',
                            'file.save ' + bee))
    pk, fk = objects(bee), folders(bee)[0]
    moved = [k for k in ('Ref voorgevel', 'Ref foto straatzijde', 'Ref plan verdieping') if k in pk and k in po and any(pk[k][f] != po[k][f] for f in ('loc', 'rot', 'scl'))]
    check(rc == 0 and len(moved) == 3, f'pinned and re-sorted: the three pages moved ({moved})')
    check(fk.get('Ref plan verdieping') != fp.get('Ref plan verdieping') and fk.get('Ref foto straatzijde') != fp.get('Ref foto straatzijde'),
          f'and into other folders ({fk.get("Ref plan verdieping")}, {fk.get("Ref foto straatzijde")})')
    check(all(v == v and abs(v) < 1e5 for o in pk.values() for f in ('loc', 'rot', 'scl') for v in o[f]), 'their places finite')

    # no poppler
    empty = os.path.join(WORK, 'emptybin')
    os.makedirs(empty, exist_ok=True)
    rc, log, _ = port(*cmds('object.add_references ' + src), env={'PATH': empty})
    check(any('PDFs left out: 8 ' in ln for ln in log) and any('1 pages from 9 files' in ln for ln in log),
          'without poppler the PDFs are left out, with a note; the photo comes in')
    rc, log, _ = port(*cmds('object.add_references ' + os.path.join(WORK, 'nothing-here')))
    check(any('no PDF or image there' in ln for ln in log), 'nothing there: it says so')


def test_fuzz():
    print('-- PDFs truncated and with bits flipped (seed 20261105) --')
    rnd = random.Random(20261105)
    d = os.path.join(WORK, 'fz')
    shutil.rmtree(os.path.join(HOME_REFS, 'fz'), ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    src = os.path.join(WORK, 'base.pdf')
    pdf(src, [sheet('S_N Doorsnede A-A', '1:100'), sheet('G_N Achtergevel', '1:100'), sheet('I_N Inplantingsplan', None)])
    base = open(src, 'rb').read()
    runs = int(os.environ.get('REF_FUZZ_RUNS', '40'))
    bad = 0
    t0 = time.time()
    for k in range(runs):
        b = bytearray(base)
        if k % 2 == 0:
            b = b[:rnd.randrange(len(b))]
        for _ in range(rnd.randrange(1, 60)):
            if b:
                b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
        if k % 5 == 0:   # a page count that lies
            b = bytes(b).replace(b'/Count 3', b'/Count 99999999')
        for n in os.listdir(d):
            os.remove(os.path.join(d, n))
        open(os.path.join(d, 'a_%d.pdf' % k), 'wb').write(bytes(b))
        open(os.path.join(d, 'b.pdf'), 'wb').write(b[:len(b) // 3])
        rc, log, err = port(*cmds('object.add_references ' + d), timeout=200)
        if rc != 0:
            bad += 1
            print('     run', k, 'exit', rc, err[-300:])
            shutil.copy(os.path.join(d, 'a_%d.pdf' % k), os.path.join(WORK, 'crash_%d.pdf' % k))
    check(bad == 0, f'{runs} damaged sets: no crash or hang ({time.time() - t0:.1f} s)')

    # a pdfinfo that lies, programs that draw nothing
    stub = os.path.join(WORK, 'stubbin')
    os.makedirs(stub, exist_ok=True)
    for n, body in (('pdfinfo', 'echo "Pages:    99999999999"'), ('pdftoppm', 'exit 1'), ('pdftotext', 'exit 1')):
        p = os.path.join(stub, n)
        open(p, 'w').write('#!/bin/sh\n' + body + '\n')
        os.chmod(p, 0o755)
    shutil.rmtree(os.path.join(HOME_REFS, 'one'), ignore_errors=True)
    os.makedirs(os.path.join(WORK, 'one'), exist_ok=True)
    open(os.path.join(WORK, 'one', 'x.pdf'), 'wb').write(b'%PDF-1.4\n')
    rc, log, _ = port(*cmds('object.add_references ' + os.path.join(WORK, 'one')), env={'PATH': stub + ':/usr/bin:/bin'}, timeout=120)
    check(rc == 0 and any('160 pages at most' in ln for ln in log) and any('could not be loaded' in ln for ln in log),
          'a PDF of 99999999999 pages: 160 at most, each said to have failed')

    # a .bee with damaged OBJS, FOLD, ANIM, MGRF, MATS, IMGS: it opens or is refused,
    # and the frame after it is drawn
    bee = os.path.join(WORK, 'fz.bee')
    png_ = os.path.join(HERE, 'files', 'reference.png')
    port(*cmds('object.add_reference ' + png_, 'object.add_references ' + os.path.join(HERE, 'files'), 'anim.range 5 40 30', 'file.save ' + bee))
    d = open(bee, 'rb').read()
    spans = {}
    o = 8
    while o + 8 <= len(d):
        s = struct.unpack('<I', d[o + 4:o + 8])[0]
        spans.setdefault(d[o:o + 4], []).append((o + 8, s))
        o += 8 + s
    runs = int(os.environ.get('REF_FUZZ_RUNS', '40'))
    bad = 0
    for k in range(runs):
        b = bytearray(d)
        t = rnd.choice([b'OBJS', b'FOLD', b'ANIM', b'MGRF', b'MATS', b'IMGS', b'OMAT'])
        at, s = spans[t][0]
        hot = min(s, 4096 if t != b'FOLD' else s)
        for _ in range(rnd.randrange(1, 40)):
            v = rnd.choice([0, 1, 255, 0x7f, 0x80, rnd.randrange(256)])
            b[at + rnd.randrange(hot)] = v
        if k % 7 == 0:   # a chunk that says it is longer
            b[at - 4:at] = struct.pack('<I', s + rnd.randrange(1, 1 << 24))
        open(bee, 'wb').write(bytes(b))
        rc, log, err = port(*cmds('file.open ' + bee), '--key', 'esc', '--move', '300,200', '--click', '300,200', timeout=60)
        if rc != 0:
            bad += 1
            print('     run', k, t, 'exit', rc, err[-400:])
            shutil.copy(bee, os.path.join(WORK, 'crash_%d.bee' % k))
    check(bad == 0, f'{runs} damaged .bee files: no crash')


# ---- the animation ----------------------------------------------------------------
def apng_chunks(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    o, out = 8, []
    while o < len(d):
        n = struct.unpack('>I', d[o:o + 4])[0]
        t = d[o + 4:o + 8]
        b = d[o + 8:o + 8 + n]
        assert struct.unpack('>I', d[o + 8 + n:o + 12 + n])[0] == zlib.crc32(t + b) & 0xffffffff, 'CRC'
        out.append((t.decode(), b))
        o += 12 + n
    return out


def apng_frames(path):
    """Each frame's RGB rows, decoded here (Sub, or any PNG filter)."""
    ch = apng_chunks(path)
    ihdr = next(b for t, b in ch if t == 'IHDR')
    w, h, depth, ctype = struct.unpack('>IIBB', ihdr[:10])
    assert depth == 8 and ctype in (2, 6)
    bpp = 3 if ctype == 2 else 4
    frames, cur = [], None
    for t, b in ch:
        if t == 'fcTL':
            if cur is not None:
                frames.append(cur)
            cur = bytearray()
        elif t == 'IDAT' and cur is not None:
            cur += b
        elif t == 'fdAT':
            cur += b[4:]
    frames.append(cur)
    out = []
    for f in frames:
        raw = zlib.decompress(bytes(f))
        s = w * bpp + 1
        prev = bytearray(s - 1)
        img = bytearray()
        for y in range(h):
            ft = raw[y * s]
            line = bytearray(raw[y * s + 1:(y + 1) * s])
            for i in range(len(line)):
                a = line[i - bpp] if i >= bpp else 0
                b_ = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                if ft == 1:
                    line[i] = (line[i] + a) & 255
                elif ft == 2:
                    line[i] = (line[i] + b_) & 255
                elif ft == 3:
                    line[i] = (line[i] + (a + b_) // 2) & 255
                elif ft == 4:
                    pa, pb, pc = abs(b_ - c), abs(a - c), abs(a + b_ - 2 * c)
                    line[i] = (line[i] + (a if pa <= pb and pa <= pc else b_ if pb <= pc else c)) & 255
            prev = line
            if bpp == 4:
                line = bytes(v for i, v in enumerate(line) if i % 4 != 3)
            img += line
        out.append((w, h, bytes(img)))
    return out


def mean_diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def probe(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries',
                        'stream=codec_name,width,height,nb_read_frames,r_frame_rate', '-of', 'csv=p=0', path],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return r.stdout.decode().strip()


def test_video():
    print('-- the animation --')
    w = os.path.join(WORK, 'vid')
    shutil.rmtree(w, ignore_errors=True)
    os.makedirs(w)
    set_ = ['render.settings 161 91 4', 'anim.range 1 12 12']
    at = lambda *p: os.path.join(w, *p)

    rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('frames')))
    got = sorted(os.listdir(at('frames'))) if os.path.isdir(at('frames')) else []
    check(got == ['%04d.png' % i for i in range(1, 13)], f'a folder: 0001.png .. 0012.png ({len(got)}; {log[-3:]})')
    check(any('rendered frames 1 to 12, ms:' in ln for ln in log), 'the console says so')
    rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('shot.png') + ' 3 5'))
    got = sorted(os.listdir(at('shot'))) if os.path.isdir(at('shot')) else []
    check(got == ['0003.png', '0004.png', '0005.png'] and not os.path.exists(at('shot.png')), f'shot.png 3 5: frames 3 to 5 ({got})')

    rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('clip.apng')))
    check(any(ln.startswith('  rendered frames 1 to 12 -> ' + at('clip.apng') + ', ms:') for ln in log), f'console: {log[-2:]}')
    ch = apng_chunks(at('clip.apng'))
    kinds = [t for t, _ in ch]
    actl = [struct.unpack('>II', b) for t, b in ch if t == 'acTL']
    fctl = [struct.unpack('>IIIIIHHBB', b) for t, b in ch if t == 'fcTL']
    seqs = [struct.unpack('>I', b[:4])[0] for t, b in ch if t in ('fcTL', 'fdAT')]
    check(kinds[:3] == ['IHDR', 'acTL', 'fcTL'] and kinds[-1] == 'IEND' and 'IDAT' in kinds and 'fdAT' in kinds, f'chunks {kinds[:5]}')
    check(actl == [(12, 0)] and len(fctl) == 12, f'acTL 12 frames, for ever ({actl})')
    check(seqs == list(range(len(seqs))), 'sequence numbers')
    check(all(c[1:3] == (161, 91) and c[5:7] == (100, 1200) for c in fctl), f'161 x 91, 100/1200 s ({fctl[0][1:7]})')
    fr = apng_frames(at('clip.apng'))
    check(len(fr) == 12 and max(mean_diff(fr[0][2], f[2]) for f in fr) < 3, 'a still scene: every frame the same, but for noise')

    # the scene saved, opened again: the same frames
    pb = at('p.bee')
    pclip = at('p.apng')
    port(*cmds(*set_, 'file.save ' + pb))
    rc, log, _ = port(*cmds('file.open ' + pb, 'render.animation ' + pclip + ' 1 3'))
    if os.path.exists(pclip):
        of = apng_frames(pclip)
        d = mean_diff(fr[0][2], of[0][2])
        check(len(of) == 3 and of[0][:2] == fr[0][:2], 'the saved scene opened again: 3 frames, the same size')
        check(d < 12, f'frame 1 against the first clip\'s: mean difference {d:.2f} of 255')
    else:
        check(False, 'no APNG from the saved scene: ' + ' '.join(log[-3:]))

    if shutil.which('ffmpeg'):
        for ext, codec, size in (('mp4', 'h264', '160,90'), ('mkv', 'h264', '160,90'), ('webm', 'vp9', '160,90'), ('gif', 'gif', '161,91')):
            rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('clip.' + ext)))
            p = probe(at('clip.' + ext)) if os.path.exists(at('clip.' + ext)) else ''
            check(p.startswith(codec + ',' + size + ',') and p.endswith(',12') and (ext == 'gif' or ',12/1,' in p), f'.{ext}: {p}')
        rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('part.mp4') + ' 4 7'))
        check(probe(at('part.mp4')).split(',')[-1] == '4', 'part.mp4 4 7: 4 frames')
        fake = at('ffmpeg-fails')
        open(fake, 'w').write("#!/bin/sh\necho \"Unknown encoder 'libx264'\" >&2\nexit 1\n")
        os.chmod(fake, 0o755)
        rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('x.mp4')), env={'BEEMODEL_FFMPEG': fake})
        check(any("ffmpeg could not make the video: Unknown encoder 'libx264'" in ln for ln in log), f'a failing ffmpeg ({log[-1:]})')
        rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('y.mp4')), env={'BEEMODEL_FFMPEG': at('no-such')})
        check(any('ffmpeg was not found' in ln for ln in log) and not os.path.exists(at('y.mp4')), 'no ffmpeg: said before anything renders')
    rc, log, _ = port(*cmds(*set_, 'render.animation /nonexistent/x/y.apng'))
    check(rc == 0 and any('not written' in ln or 'could not' in ln for ln in log), f'a place it cannot write ({log[-1:]})')
    rc, log, _ = port(*cmds(*set_, 'render.animation ' + at('z.apng') + ' 9 2'))
    check(rc == 0 and any('could not' in ln for ln in log), 'first after last: no crash')
    # the frame range in a file: written, read back
    pb2 = at('r.bee')
    port(*cmds('anim.range 5 40 30', 'file.save ' + pb2))
    c = chunks(pb2)[b'ANIM'][0]
    check(struct.unpack('<iif', c[28:40]) == (5, 40, 30.0) and len(c) == 71300, 'the range in ANIM')
    rc, log, _ = port(*cmds('file.open ' + pb2, 'file.save ' + pb2 + '2'))
    c = chunks(pb2 + '2')[b'ANIM'][0]
    check(struct.unpack('<iif', c[28:40]) == (5, 40, 30.0), 'and read back, saved again')


def test_esc():
    print('-- Esc, in a real window (a fake compositor) --')
    home = tempfile.mkdtemp(prefix='bee-esc-', dir='/tmp')
    f = fake_wl(BIN, home)
    out = os.path.join(WORK, 'esc')
    shutil.rmtree(out, ignore_errors=True)
    out2 = os.path.join(WORK, 'esc2.apng')

    def console(c):
        f.key(28)
        typ(f, c)
        f.key(28)
        f.pump(0.2)

    def settled(d):
        t1 = time.time()
        while time.time() - t1 < 30:
            f.pump(0.2)
            n = len(os.listdir(d))
            f.pump(0.5)
            if len(os.listdir(d)) == n:
                break
        return len(os.listdir(d))

    # frames quicker than the job's window updates: Esc is looked at after each
    quick = os.path.join(WORK, 'escq')
    shutil.rmtree(quick, ignore_errors=True)
    console('render.settings 64 36 4')
    console('render.animation ' + quick + ' 1 200')
    t0 = time.time()
    while time.time() - t0 < 60 and not (os.path.isdir(quick) and len(os.listdir(quick)) >= 2):
        f.pump(0.01)
    f.key(1)
    n = settled(quick)
    check(2 <= n < 60, f'Esc on quick frames: {n} frames of 200 kept')

    console('render.settings 320 180 64')
    console('render.animation ' + out + ' 1 200')
    t0 = time.time()
    while time.time() - t0 < 60 and not (os.path.isdir(out) and len(os.listdir(out)) >= 2):
        f.pump(0.05)
    f.key(1)
    t1 = time.time()
    n0 = len(os.listdir(out))
    while time.time() - t1 < 30:
        f.pump(0.2)
        n = len(os.listdir(out))
        time.sleep(0.3)
        if len(os.listdir(out)) == n:
            f.pump(0.5)
            if len(os.listdir(out)) == n:
                break
    n = len(os.listdir(out))
    check(2 <= n <= n0 + 2 and n < 200, f'Esc stops after the frame it is on: {n} frames of 200 kept')
    # the window is alive, and a stopped APNG plays what it has
    console('render.animation ' + out2 + ' 1 200')
    t0 = time.time()
    time.sleep(1.5)
    f.pump(0.2)
    f.key(1)
    t0 = time.time()
    while time.time() - t0 < 30 and not os.path.exists(out2):
        f.pump(0.2)
    f.pump(2.0)
    ok = False
    for _ in range(20):
        try:
            ch = apng_chunks(out2)
            ok = ch[-1][0] == 'IEND'
            if ok:
                break
        except Exception:
            pass
        f.pump(0.5)
    if ok:
        actl = [struct.unpack('>II', b) for t, b in ch if t == 'acTL'][0]
        nf = len([1 for t, _ in ch if t == 'fcTL'])
        check(actl[0] == nf and 1 <= nf < 200, f'a stopped APNG says how many it has: {actl[0]} frames, {nf} there')
    else:
        check(False, 'the stopped APNG has no end')
    # the window keeps drawing a Rendered viewport while the frames render
    out3 = os.path.join(WORK, 'esc3')
    shutil.rmtree(out3, ignore_errors=True)
    f.key(1)
    console('view.rendered_samples 8')
    console('view.shading_rendered')
    f.pump(1.0)
    console('render.settings 96 54 8')
    console('render.animation ' + out3 + ' 1 6')
    t0 = time.time()
    while time.time() - t0 < 40 and not (os.path.isdir(out3) and len(os.listdir(out3)) == 6):
        f.pump(0.2)
    check(os.path.isdir(out3) and len(os.listdir(out3)) == 6 and f.proc.poll() is None, 'with a Rendered viewport open: 6 frames, the window alive')
    err = f.close()
    check('panic' not in err, f'no panic in the window ({err.strip()[-200:]})')
    shutil.rmtree(home, ignore_errors=True)


def main():
    if not os.path.exists(BIN):
        sys.exit('no ' + BIN)
    which = sys.argv[2:] or ['set', 'fuzz', 'video', 'esc']
    if 'set' in which:
        test_set()
    if 'fuzz' in which:
        test_fuzz()
    if 'video' in which:
        test_video()
    if 'esc' in which:
        test_esc()
    print('fails', len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
