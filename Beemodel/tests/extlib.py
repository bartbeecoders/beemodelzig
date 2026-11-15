#!/usr/bin/env python3
"""Online library sources (extlib.zig), BeeModel on its own, with no network:
BeeModel and a stand-in server run in a network namespace of their own
(unshare -rn: only the loopback; a connection out fails, checked first). The
server plays Hugging Face (a SimReady-layout dataset: the tree API two
entries a page with Link headers, paths-info, recursive listings, resolve
through a redirect) and Poly Haven's API (the models' catalog, /files/<id>,
thumbnails, downloads); its fixtures are made here. BEEMODEL_HF_URL and
BEEMODEL_PH_URL point BeeModel at it.

  * lib.source simready: catalog.tsv (every page, roots .usd before .usda,
    none for an asset without USD); the next time read from the cache, the
    server not asked; lib.refresh asks again.
  * lib.get: only the files an import needs fetched (not source_assets/,
    .thumbs/, .mdl), the server's bytes, the .complete marker; a second
    lib.get fetches nothing; a file the server fails on: "could not all be
    fetched", the rest kept. Then the USD is imported (file.import_usd) and
    credited.
  * Poly Haven: the catalog (categories and tags kept for the search, the
    thumbnail's URL without its query); lib.get reads /files/<id>: the 1k
    USD and its include map, an EXR fetched as its map's JPEG, a path leaving
    the folder refused; User-Agent BeeModel/...
  * ~/BeeModel/sources.txt adds a source; lib.sources lists them; lib.source
    of an unknown id, lib.get of an unknown asset or with no source shown:
    refused.
  * The Asset Browser on an online source, from the cache: drawn; the search
    (lib.search) narrows the tiles.

    python3 tests/extlib.py BIN

BEE_CPU (default 18) pins BeeModel.
"""
import http.server, json, os, pwd, shutil, socketserver, struct, subprocess, sys, tempfile, threading, time, urllib.parse, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
CPU = os.environ.get('BEE_CPU', '18')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def real_state(h):
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel', 'BeeModel'):
        for root, dirs, files in os.walk(os.path.join(h, d)):
            for nm in dirs + files:
                p = os.path.join(root, nm)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                out[os.path.relpath(p, h)] = (st.st_size, st.st_mtime_ns)
    return out


if os.environ.get('EXT_INNER') != '1':
    # the outside: the real home's state (found by uid), then the test in a
    # network namespace of its own, then the state again
    real = pwd.getpwuid(os.getuid()).pw_dir
    before = real_state(real)
    env = dict(os.environ, EXT_INNER='1', EXT_REAL=real)
    r = subprocess.run(['unshare', '-rn', sys.executable, os.path.abspath(__file__), *sys.argv[1:]], env=env)
    after = real_state(real)
    ch = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    print(('  ok   ' if not ch else '  FAIL ') + f'the real ~/BeeModel and ~/.config/beemodel{{,-zig}} untouched ({len(after)} entries; changed {ch[:4]})')
    fails = r.returncode + (1 if ch else 0)
    print(f'\nonline libraries: fails {fails}')
    sys.exit(1 if fails else 0)

# ---- the inside: no network but the loopback -----------------------------------------------

import temphome  # noqa: E402,F401 (a HOME of our own)

subprocess.run(['ip', 'link', 'set', 'lo', 'up'], capture_output=True)
T = tempfile.mkdtemp(prefix='beeext-', dir='/tmp')
HUB = os.path.join(T, 'hub')
PHD = os.path.join(T, 'ph')
LOG = []
UA = []
FAIL_PATHS = set()
REPO = 'nvidia/simready-assets'


def png(w, h, rgba):
    raw = b''.join(b'\0' + b''.join(bytes(rgba(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def put(rel, data):
    p = os.path.join(HUB, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(data if isinstance(data, bytes) else data.encode())


def fixtures():
    """A SimReady-layout dataset: two assets with USD roots (.usd, .usda),
    what an import does not need beside them, one with none; Poly Haven's
    models."""
    put('crate_test_a01/simready_usd/sm_crate_test_a01_01.usd', '#usda 1.0\n(defaultPrim = "Crate")\ndef Xform "Crate" {}\n')
    put('crate_test_a01/simready_usd/sm_crate_test_a01_01.usda', '#usda 1.0\n')
    put('crate_test_a01/simready_usd/textures/crate_albedo.png', png(4, 4, lambda x, y: (200, 120, 40, 255)))
    put('crate_test_a01/simready_usd/.thumbs/256x256/sm_crate_test_a01_01.usd.png', png(32, 24, lambda x, y: (40 + x * 5, 80 + y * 4, 160, 255)))
    put('crate_test_a01/simready_usd/materials/crate.mdl', 'mdl 1.6;\n')
    put('crate_test_a01/source_assets/crate.max', b'\0' * 300)
    put('table_test_b02/simready_usd/sm_table_test_b02_01.usda', '#usda 1.0\n(defaultPrim = "Table")\ndef Xform "Table" {}\n')
    put('table_test_b02/simready_usd/payloads/table_geo.usda', '#usda 1.0\n')
    put('table_test_b02/simready_usd/textures/table_wood.png', png(8, 8, lambda x, y: (120, 90 + x * 10, 60, 255)))
    put('table_test_b02/simready_usd/.thumbs/256x256/sm_table_test_b02_01.usda.png', png(20, 30, lambda x, y: (220, 200, 30 + y * 6, 128 + x * 6)))
    put('noroot_x01/readme.txt', 'nothing here\n')
    for k in range(5):
        put(f'box_k{k:02d}/simready_usd/sm_box_k{k:02d}_01.usd', f'#usda 1.0\n# box {k}\n')
    os.makedirs(PHD, exist_ok=True)
    for nm, data in (('crate.usd', '#usda 1.0\ndef "Crate" {}\n'), ('table.usda', '#usda 1.0\ndef "Table" {}\n'),
                     ('diff.jpg', b'\xff\xd8diff'), ('metal.jpg', b'\xff\xd8metal'), ('metal.exr', b'v/1\x01exr'),
                     ('rough.jpg', b'\xff\xd8rough'), ('thumb.png', png(16, 24, lambda x, y: (90, 160, 90, 255 if x > 3 else 0)))):
        open(os.path.join(PHD, nm), 'wb').write(data if isinstance(data, bytes) else data.encode())


PH_DL = {}


def ph_assets(host):
    th = lambda i: f'{host}/phcdn/thumbs/{i}.png?width=256&height=256&format=webp'
    return {'crate_ph': {'name': 'Crate', 'categories': ['props', 'containers'], 'tags': ['wood', 'box'], 'thumbnail_url': th('crate_ph')},
            'nousd_ph': {'name': 'No USD', 'categories': ['props'], 'tags': [], 'thumbnail_url': th('nousd_ph')},
            'table_ph': {'name': 'Table', 'categories': ['furniture', 'tables'], 'tags': ['Table', 'wooden \\"oak\\"'], 'thumbnail_url': th('table_ph')}}


def ph_files(host):
    def f(kind, res, i, name, src):
        path = f'/phdl/{kind}/{res}/{i}/{name}'
        PH_DL[path] = src
        return {'url': host + path, 'size': os.path.getsize(src), 'md5': 'x'}
    s = lambda n: os.path.join(PHD, n)
    maps = {'Diffuse': {'1k': {'jpg': f('jpg', '1k', 'table_ph', 'table_diff_1k.jpg', s('diff.jpg'))}},
            'Metal': {'1k': {'jpg': f('jpg', '1k', 'table_ph', 'table_metal_1k.jpg', s('metal.jpg')),
                             'exr': f('exr', '1k', 'table_ph', 'table_metal_1k.exr', s('metal.exr'))}},
            'Rough': {'1k': {'jpg': f('jpg', '1k', 'table_ph', 'table_rough_1k.jpg', s('rough.jpg'))}}}
    inc = {'textures/table_diff_1k.jpg': maps['Diffuse']['1k']['jpg'], 'textures/table_metal_1k.exr': maps['Metal']['1k']['exr'],
           'textures/table_rough_1k.jpg': maps['Rough']['1k']['jpg'],
           '../../escape.txt': f('jpg', '1k', 'table_ph', 'escape.txt', s('diff.jpg'))}
    table = dict(maps)
    table['usd'] = {'2k': {'usd': dict(f('usd', '2k', 'table_ph', 'table_2k.usda', s('table.usda')), include={})},
                    '1k': {'usd': dict(f('usd', '1k', 'table_ph', 'table_1k.usda', s('table.usda')), include=inc)}}
    return {'crate_ph': {'usd': {'1k': {'usd': dict(f('usd', '1k', 'crate_ph', 'crate_ph_1k.usd', s('crate.usd')), include={})}}},
            'nousd_ph': {'blend': {'1k': {'blend': f('blend', '1k', 'nousd_ph', 'x.blend', s('crate.usd'))}}},
            'table_ph': table}


class Stand(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def send(self, code, body=b'', ctype='application/json', headers=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        LOG.append(('GET', u.path, u.query))
        host = 'http://' + self.headers['Host']
        if u.path.startswith('/ph'):
            UA.append(self.headers.get('User-Agent', ''))
            if u.path == '/ph/assets':
                return self.send(200, json.dumps(ph_assets(host)).encode()) if q.get('t') == ['models'] else self.send(400, b'{}')
            if u.path.startswith('/ph/files/'):
                fl = ph_files(host).get(u.path[len('/ph/files/'):])
                return self.send(200, json.dumps(fl).encode()) if fl else self.send(404, b'{}')
            if u.path.startswith('/phcdn/'):
                return self.send(200, open(os.path.join(PHD, 'thumb.png'), 'rb').read(), 'image/png') if 'format=png' in u.query \
                    else self.send(200, b'RIFF....WEBP', 'image/webp')
            ph_files(host)
            src = PH_DL.get(u.path)
            return self.send(200, open(src, 'rb').read(), 'application/octet-stream') if src else self.send(404, b'{}')
        if u.path.startswith('/cdn/'):
            rel = urllib.parse.unquote(u.path[5:])
            if rel in FAIL_PATHS:
                return self.send(500, b'oops', 'text/plain')
            p = os.path.join(HUB, rel)
            return self.send(200, open(p, 'rb').read(), 'application/octet-stream') if os.path.isfile(p) else self.send(404, b'{}')
        if '/resolve/main/' in u.path:
            return self.send(302, b'', headers=[('Location', '/cdn/' + u.path.split('/resolve/main/', 1)[1])])
        p = u.path.split('/')
        if len(p) < 6 or p[1:3] != ['api', 'datasets']:
            return self.send(404, b'{}')
        rest = '/'.join(p[5:])
        if not rest.startswith('tree/main'):
            return self.send(404, b'{}')
        rest = rest[len('tree/main'):].lstrip('/')
        base = os.path.join(HUB, rest)
        if not os.path.isdir(base):
            return self.send(404, b'{"error":"no such path"}')
        if 'recursive' in q:
            items = []
            for root, dirs, files in os.walk(base):
                items += [{'type': 'directory', 'oid': 'x', 'path': os.path.relpath(os.path.join(root, d), HUB)} for d in dirs]
                items += [{'type': 'file', 'oid': 'x', 'size': os.path.getsize(os.path.join(root, fn)),
                           'path': os.path.relpath(os.path.join(root, fn), HUB)} for fn in files]
        else:
            items = [{'type': 'directory' if os.path.isdir(os.path.join(base, nm)) else 'file', 'oid': 'x',
                      'path': os.path.join(rest, nm) if rest else nm} for nm in sorted(os.listdir(base))]
            items.append({'type': 'file', 'oid': 'x', 'size': 9, 'path': '.gitattributes'})
        items.sort(key=lambda i: i['path'])
        start = int(q.get('cursor', ['0'])[0])
        per = 2 if not rest else 3
        hdr = []
        if start + per < len(items):
            nxt = 'http://%s%s?%scursor=%d' % (self.headers['Host'], u.path, 'recursive=true&' if 'recursive' in q else '', start + per)
            hdr.append(('Link', '<%s>; rel="next"' % nxt))
        self.send(200, json.dumps(items[start:start + per]).encode(), headers=hdr)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        LOG.append(('POST', u.path, body))
        if not u.path.endswith('/paths-info/main'):
            return self.send(404, b'{}')
        form = urllib.parse.parse_qs(body)
        out = [{'type': 'file', 'oid': 'x', 'size': os.path.getsize(os.path.join(HUB, pp)), 'path': pp}
               for pp in form.get('paths', []) if os.path.isfile(os.path.join(HUB, pp))]
        self.send(200, json.dumps(out).encode())


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def home(name):
    h = os.path.join(T, name)
    shutil.rmtree(h, True)
    os.makedirs(os.path.join(h, 'BeeModel'))
    return h


def envs(h, port):
    return dict(os.environ, HOME=h, XDG_CACHE_HOME='', BEEMODEL_HF_URL=f'http://127.0.0.1:{port}',
                BEEMODEL_PH_URL=f'http://127.0.0.1:{port}/ph', BEEMODEL_GH_URL=f'http://127.0.0.1:{port}/gh')


def port_(h, port, *ops):
    lg = os.path.join(h, 'log.txt')
    if os.path.exists(lg):
        os.remove(lg)
    a = []
    for o in ops:
        a += ['--op', o]
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', os.path.join(h, 'u.ppm'), '--dump-log', lg, *a],
                       capture_output=True, text=True, timeout=600, env=envs(h, port))
    if r.returncode != 0:
        print(r.stderr[-1500:])
    return r.returncode, open(lg, errors='replace').read() if os.path.exists(lg) else ''


def run(port, h, ops):
    LOG.clear()
    rc, lg = port_(h, port, *ops)
    return rc, list(LOG), lg


def cache(h, src):
    out = {}
    d = os.path.join(h, 'BeeModel', 'cache', src)
    for root, dirs, files in os.walk(d):
        for fn in files:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, d)
            if rel.startswith(('page.', 'list.', 'info.', 'assets.json')):
                continue
            out[rel] = open(p, 'rb').read()
    return out


def paths(log):
    return [(m, p) for m, p, _ in log]


def same_as_hub(files, asset):
    """The fetched files of an asset: [(path, the same bytes as the server's)]."""
    pre = f'assets/{asset}/'
    return [(k, open(os.path.join(HUB, asset, k[len(pre):]), 'rb').read() == v if os.path.isfile(os.path.join(HUB, asset, k[len(pre):])) else None)
            for k, v in files.items() if k.startswith(pre) and not k.endswith('/.complete')]


def main():
    print(f'  BeeModel {BIN}')
    r = subprocess.run(['curl', '-sS', '-m', '5', '-o', '/dev/null', 'http://1.1.1.1/'], capture_output=True)
    check(r.returncode != 0, f'no network here: a connection out fails (curl {r.returncode})')
    fixtures()
    srv = Server(('127.0.0.1', 0), Stand)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        print('-- SimReady: the catalog, the files --')
        hp = home('p')
        rc, lp, lg = run(port, hp, ['lib.source simready'])
        cat = cache(hp, 'simready').get('catalog.tsv', b'').decode()
        check(rc == 0 and 'crate_test_a01\tcrate_test_a01/simready_usd/sm_crate_test_a01_01.usd\tcrate' in cat,
              f'catalog.tsv: the crate, its root the .usd (not the .usda) ({len(cat.splitlines())} assets)')
        check('noroot_x01\t\tnoroot' in cat, 'catalog.tsv: an asset with no USD has no root')
        check(len(cat.splitlines()) == 8 and '  catalog: 8 assets in NVIDIA SimReady' in lg,
              'every page read (the Link headers followed): "catalog: 8 assets in NVIDIA SimReady"')
        check(len(lp) >= 5 and len(set((m, p, q) for m, p, q in lp)) == len(lp) and any(m == 'POST' for m, _, _ in lp),
              f'{len(lp)} requests (pages, paths-info), none twice')
        rc, lp, lg = run(port, hp, ['lib.source simready'])
        check(rc == 0 and not lp, f'the next time: catalog.tsv read, the server not asked ({len(lp)} requests)')
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.refresh'])
        check(rc == 0 and len(lp) >= 5, f'lib.refresh: the catalog asked again ({len(lp)} requests)')
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.get crate_test_a01 1 2 3'])
        cp = cache(hp, 'simready')
        fp = sorted(k for k in cp if k.startswith('assets/'))
        sh = same_as_hub(cp, 'crate_test_a01')
        check(rc == 0 and len(fp) >= 3 and 'assets/crate_test_a01/.complete' in cp and sh and all(x[1] for x in sh),
              f'lib.get crate_test_a01: the files, the server\'s bytes, the .complete marker ({fp})')
        check(not any(('source_assets' in k or '.thumbs' in k or k.endswith('.mdl')) for k in fp),
              'only what an import needs: no source_assets/, .thumbs/ or .mdl')
        check('  usd: 0 objects from 0 meshes, 0 skipped' in lg and '  placed crate_test_a01 - NVIDIA SimReady, CC-BY 4.0' in lg,
              'then the USD imported (file.import_usd: no meshes in this one) and credited')
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.get crate_test_a01'])
        check(rc == 0 and not [x for x in lp if '/cdn/' in x[1]], 'a second lib.get: nothing fetched (the .complete marker)')
        FAIL_PATHS.add('table_test_b02/simready_usd/payloads/table_geo.usda')
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.get table_test_b02'])
        FAIL_PATHS.clear()
        cp = cache(hp, 'simready')
        fp = sorted(k for k in cp if k.startswith('assets/table'))
        check(rc == 0 and '  the asset\'s files could not all be fetched: table_test_b02' in lg and
              'assets/table_test_b02/.complete' not in fp and len(fp) >= 1, f'a file the server fails on: not placed, said so, the rest kept ({fp})')
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.get table_test_b02'])
        cp = cache(hp, 'simready')
        sh = same_as_hub(cp, 'table_test_b02')
        check(rc == 0 and 'assets/table_test_b02/.complete' in cp and 'assets/table_test_b02/simready_usd/payloads/table_geo.usda' in cp
              and sh and all(x[1] for x in sh), 'once the server works again: it comes, the server\'s bytes')
        rc, lp, lg = run(port, hp, ['lib.get crate_test_a01', 'lib.source simready', 'lib.get nothing_here', 'lib.source nowhere'])
        check('  lib.get <asset> (in the current source; lib.source <id> first)' in lg and '  no such asset in this source: nothing_here' in lg
              and '  no such library source: nowhere' in lg and not lp, 'refused: no source shown, an unknown asset, an unknown source')
        # the search over the catalog
        rc, lp, lg = run(port, hp, ['lib.source simready', 'lib.search box k03'])
        check(rc == 0 and not lp, 'lib.search over the catalog: runs, the server not asked')

        print('-- sources.txt --')
        b = home('sp')
        open(os.path.join(b, 'BeeModel', 'sources.txt'), 'w').write('# mine\nsimready mine acme/props My props\n')
        rc, lp, lg = run(port, b, ['lib.sources', 'lib.source mine'])
        check('    mine -  My props' in lg and '    polyhaven - Poly Haven' in lg and '    local' in lg,
              'lib.sources lists the local library, the three sources and sources.txt\'s')
        check(lp and lp[0][1] == '/api/datasets/acme/props/tree/main', f'lib.source mine asks for its own dataset ({lp[:1]})')

        print('-- Poly Haven --')
        hp = home('hp')
        UA.clear()
        rc, lp, lg = run(port, hp, ['lib.source polyhaven'])
        cat = (cache(hp, 'polyhaven').get('catalog.tsv') or b'').decode()
        crate = [ln for ln in cat.splitlines() if ln.startswith('crate_ph\t')]
        check(rc == 0 and len(cat.splitlines()) == 3 and crate, f'the catalog: catalog.tsv, 3 models ({cat.splitlines()[:1]})')
        check(crate and 'props' in crate[0] and 'wood' in crate[0] and '/phcdn/thumbs/crate_ph.png' in crate[0] and '?' not in crate[0],
              'the crate: its categories and tags kept for the search, the thumbnail\'s URL without its query')
        check(paths(lp) == [('GET', '/ph/assets')], 'one request')
        for asset in ('crate_ph', 'table_ph', 'nousd_ph'):
            rc, lp, lg = run(port, hp, ['lib.source polyhaven', f'lib.get {asset}'])
            cp = cache(hp, 'polyhaven')
            fp = sorted(k for k in cp if k.startswith(('assets/', 'bom/')) and asset in k)
            check(rc == 0 and (fp if asset != 'nousd_ph' else not [k for k in fp if k.startswith('assets/')]),
                  f'lib.get {asset}: {len(lp)} requests; {fp}')
        check(cp.get('assets/crate_ph/crate_ph_1k.usd') == open(os.path.join(PHD, 'crate.usd'), 'rb').read()
              and cp.get('assets/table_ph/textures/table_diff_1k.jpg') == open(os.path.join(PHD, 'diff.jpg'), 'rb').read(),
              'the 1k USD and its include map fetched: the server\'s bytes')
        check('assets/table_ph/textures/table_metal_1k.jpg' in cp and 'assets/table_ph/textures/table_metal_1k.exr' not in cp
              and not any('escape' in k for k in cp), 'an EXR fetched as its map\'s JPEG; a path leaving the folder refused')
        check('  no USD root in the asset\'s package: nousd_ph' in lg, 'no USD offered: said so')
        check(UA and all(u.startswith('BeeModel/') for u in UA), f'every request says User-Agent: BeeModel/... ({sorted(set(UA))})')

        print('-- the Asset Browser on an online source --')
        from PIL import Image
        cases = [('the SimReady tiles', 'simready', '', (80, 120)),
                 ('a search', 'simready', 'box k0', (80, 120)),
                 ('Poly Haven\'s tiles', 'polyhaven', '', (300, 300))]
        for label, sid, words, click in cases:
            pw = home('wp')
            for src in ('p', 'hp'):
                shutil.copytree(os.path.join(T, src, 'BeeModel', 'cache'), os.path.join(pw, 'BeeModel', 'cache'), dirs_exist_ok=True)
            LOG.clear()
            r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', os.path.join(pw, 'u.ppm'), '--op', 'area.type_asset_browser',
                                '--op', 'area.maximize', '--op', f'lib.source {sid}', '--op', f'lib.search {words}',
                                '--click', f'{click[0]},{click[1]}', '--move', '600,500'], capture_output=True, env=envs(pw, port), timeout=600)
            ok = r.returncode == 0 and os.path.exists(os.path.join(pw, 'u.ppm'))
            if ok:
                Image.open(os.path.join(pw, 'u.ppm')).save(os.path.join(T, f'p_{sid}{len(words)}.png'))
            # (one frame, then it ends: the thumbnails are asked for, not waited for)
            asked = sorted(set(p for _, p, _ in LOG if '/thumbs/' in p or '/.thumbs/' in p))
            check(ok and len(asked) >= 2, f'{label}: drawn, the shown tiles\' thumbnails asked for ({len(asked)})')
        a, b2 = os.path.join(T, 'p_simready0.png'), os.path.join(T, 'p_simready6.png')
        if os.path.exists(a) and os.path.exists(b2):
            from PIL import ImageChops
            d = ImageChops.difference(Image.open(a).convert('RGB'), Image.open(b2).convert('RGB')).load()
            nd = sum(1 for y in range(80, 780) for x in range(130, 1180) if max(d[x, y]) > 30)
            check(nd > 0, f'the search narrows the tiles: {nd} pixels changed')
    finally:
        srv.shutdown()
        shutil.rmtree(T, True)
    print(f'\ninside: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


main()
