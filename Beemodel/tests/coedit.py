#!/usr/bin/env python3
"""Live co-editing (cosync.zig, cotree.zig), BeeModel peers on their own: each in
its fake compositor (tests/wl_fake.py), driven through MCP, on loopback only
(127.0.0.1, ports picked free), with raw test peers written here.

  words   the operators' console words, the MCP tools, costat / cohash replies
          (two BeeModels: the same replies)
  host    what a host sends a joining test peer: HELLO and the document as
          operations; hosted twice, the same messages byte for byte (the peer
          ids rewritten: every program has its own)
  join    a test peer hosts a crafted document (meshes, a deleted element, a
          vertex newer than its generation, materials, a node tree): the scene
          a BeeModel builds, then the operations it sends for the same edits;
          joined twice, the same bytes
  two     two peers in one session: the same documents (cohash), scenes and
          saved .bee files (decoded); hosting is no edit to undo; then out of
          the session the scene's own undo steps back
  chain   three peers, each joining the one before (no server): hundreds of
          random edits on all three at once converge
  undo    undo per author (Ctrl+Z in the window takes back your own edit only,
          on every peer; Ctrl+Shift+Z again); a grab under way while an edit
          comes in
  agent   co.agent on: what tools change is the agent's peer (its operations,
          presence, own undo)
  key     session keys: tags checked by a test peer, keyed sessions, a peer
          without the key or with another refused
  pres    presence: peers seen, co.follow, the drawn selections, cameras and
          cursors
  ui      the Versions editor's Collaboration section and the status bar's
          chip; Follow clicked
  fuzz    damaged, partial, oversized, reordered, duplicated messages, peers
          that vanish mid-message, too many peers: no panic, no hang, no
          growth; the session goes on

    python3 tests/coedit.py BIN [rounds=200]

COEDIT_ONLY=a,b runs some sections; BEE_CPU (default 10) pins the programs.
Ends with "... fails N".
"""
import json, os, random, re, shutil, socket, struct, sys, tempfile, time, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 200
CPU = int(os.environ.get('BEE_CPU', '10'))
ONLY = [x for x in os.environ.get('COEDIT_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='bco-', dir='/tmp')
tempfile.tempdir = T   # (the fake compositors' folders too: all go at the end)


def check(cond, msg, detail=None):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)
        if detail is not None:
            print('       ' + str(detail)[:900])
    return cond


def section(name):
    return not ONLY or name in ONLY


# ---- the programs ------------------------------------------------------------------------------

ALL = []
PANICS = []


class Prog:
    """One BeeModel in its fake compositor (1280 x 800), an MCP client on its socket.
    (which: a name for the reports.)"""

    def __init__(self, which='port', size=(1280, 800)):
        self.which = which
        self.home = tempfile.mkdtemp(prefix='h', dir=T)
        env = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0', 'BEEMODEL_AGENT_PERMISSION': 'files'}
        from wl_fake import Fake
        env.update(HOME=self.home, XDG_RUNTIME_DIR=self.home, XDG_CACHE_HOME=os.path.join(self.home, 'cache'))
        self.f = Fake(BIN, size=size, env=env)
        self.f.until(lambda: self.f.frames > 0, 15)
        self.f.enter(640, 300)
        ALL.append(self)
        try:
            os.sched_setaffinity(self.f.proc.pid, {CPU})
        except OSError:
            pass
        self.pump(0.2)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(100):
            try:
                self.s.connect(os.path.join(self.home, 'beemodel.sock'))
                break
            except OSError:
                self.pump(0.1)
        self.s.setblocking(False)
        self.buf = b''
        self.rid = 0

    def pump(self, t=0.05):
        self.f.pump(t)

    def alive(self):
        return self.f.proc.poll() is None

    def call(self, method, params=None, timeout=15.0):
        self.rid += 1
        rid = self.rid
        m = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params is not None:
            m['params'] = params
        try:
            self.s.sendall(json.dumps(m).encode() + b'\n')
        except OSError:
            return None
        end = time.time() + timeout
        while time.time() < end:
            while b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get('id') == rid:
                    return r
            self.pump(0.01)
            try:
                c = self.s.recv(1 << 22)
                if c == b'':
                    return None
                self.buf += c
            except BlockingIOError:
                pass
            except OSError:
                return None
        return None

    def tool(self, name, args=None):
        r = self.call('tools/call', {'name': name, 'arguments': args or {}})
        try:
            res = r['result']
            return res['content'][0]['text'], res.get('isError')
        except (TypeError, KeyError, IndexError):
            return None, None

    def q(self, code):
        t, _ = self.tool('script_eval', {'code': code})
        return (t or '').strip()

    def image(self):
        from PIL import Image
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def frames(self):
        return self.f.frames

    def shot(self, wait=0.6):
        """The window after a fresh frame (an input-free change asks for one)."""
        n = self.frames()
        end = time.time() + wait
        while time.time() < end:
            self.pump(0.03)
        if self.frames() == n:
            self.pump(0.3)
        return self.image()

    def keyz(self, shift=False):
        """Ctrl+Z (Ctrl+Shift+Z) in the window, the pointer over the viewport."""
        m = 5 if shift else 4
        self.f.motion(640, 300)
        self.f.key(44, m)
        self.pump(0.1)

    def mouse(self, x, y):
        self.f.motion(x, y)

    def click(self, x, y):
        self.f.click(x, y)
        self.pump(0.1)

    def kill(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            self.f.proc.kill()
            self.f.proc.wait(5)
        except Exception:
            pass
        try:
            err = self.f.proc.stderr.read().decode(errors='replace')
            if 'panic' in err or 'leak' in err.lower() or 'error(gpa)' in err:
                PANICS.append(err[-2000:])
        except Exception:
            pass
        shutil.rmtree(getattr(self.f, 'dir', None) or '/nonexistent', True)
        if self in ALL:
            ALL.remove(self)


def pump_all(progs, n=8, t=0.02):
    for _ in range(n):
        for p in progs:
            p.pump(t)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ---- the wire ------------------------------------------------------------------------------------

PEERS = []


class Peer:
    """A raw test peer on loopback: what a program sends it, message by message."""

    def __init__(self, port=None, sock=None):
        self.s = sock or socket.create_connection(('127.0.0.1', port), timeout=5)
        self.s.setblocking(False)
        self.buf = b''
        self.msgs = []
        self.closed = False
        PEERS.append(self)

    def poll(self):
        while True:
            try:
                c = self.s.recv(1 << 22)
            except BlockingIOError:
                break
            except OSError:
                self.closed = True
                return False
            if not c:
                self.closed = True
                return False
            self.buf += c
        while len(self.buf) >= 4:
            n = struct.unpack_from('<I', self.buf)[0]
            if len(self.buf) < n + 4:
                break
            self.msgs.append(self.buf[:n + 4])
            self.buf = self.buf[n + 4:]
        return True

    def send(self, b):
        try:
            self.s.setblocking(True)
            self.s.sendall(b)
            self.s.setblocking(False)
            return True
        except OSError:
            return False

    def take(self):
        m, self.msgs = self.msgs, []
        return m

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        if self in PEERS:
            PEERS.remove(self)


class Listener:
    """A test peer that hosts: the program joins it."""

    def __init__(self):
        self.l = socket.socket()
        self.l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.l.bind(('127.0.0.1', 0))
        self.l.listen(8)
        self.l.setblocking(False)
        self.port = self.l.getsockname()[1]

    def accept(self):
        try:
            c, _ = self.l.accept()
            return Peer(sock=c)
        except BlockingIOError:
            return None

    def close(self):
        self.l.close()


def msg(t, origin, num, payload):
    return struct.pack('<IBHI', 7 + len(payload), t, origin, num) + payload


def hello(origin=0x1235, num=1, nonce=None):
    p = b'BEEL' + struct.pack('<I', 1 | (2 << 16))
    if nonce is not None:
        p += struct.pack('<Q', nonce)
    return msg(40, origin, num, p)


def parse(m):
    n, t, o, num = struct.unpack_from('<IBHI', m)
    return t, o, num, m[11:]


def pres(origin, num, name, cam=(0.0,) * 6, cur=(0.0, 0.0, 0.0), sel=()):
    nm = name.encode()[:16].ljust(16, b'\0')
    pl = struct.pack('<I', origin) + nm + struct.pack('<6f', *cam) + struct.pack('<3f', *cur) + struct.pack('<I', len(sel)) + b''.join(struct.pack('<Q', s) for s in sel)
    return msg(47, origin, num, pl)


def peer_of(msgs):
    """A program's peer id: its HELLO's origin."""
    for m in msgs:
        if m[4] == 40:
            return struct.unpack_from('<H', m, 5)[0] & 0x7fff
    return None


U64_AT = {41: (0, 8, 16), 42: (0, 8), 43: (0, 8), 44: (0, 8, 16), 45: (0, 8, 16), 46: (32,), 48: (32,), 49: (32,),
          50: (32, 40, 48), 51: (32, 40), 52: (32, 40, 120, 128, 136)}


def norm(m, peer):
    """A message with a program's peer id rewritten (0x7fff): in its origin, in
    every timestamp and id it carries; a presence's "user-XX"; the bytes after a
    colour register's value zeroed."""
    b = bytearray(m)
    o = struct.unpack_from('<H', b, 5)[0]
    if o & 0x7fff == peer:
        struct.pack_into('<H', b, 5, 0x7fff | (o & 0x8000))
    t = b[4]
    P = 11

    def fix64(at):
        if at + 8 > len(b):
            return
        x = struct.unpack_from('<Q', b, at)[0]
        if x & 0x7fff == peer:
            struct.pack_into('<Q', b, at, x | 0x7fff)

    def fix32(at):
        if at + 4 > len(b):
            return
        x = struct.unpack_from('<I', b, at)[0]
        if x & 0x7fff == peer:
            struct.pack_into('<I', b, at, x | 0x7fff)

    for at in U64_AT.get(t, ()):
        fix64(P + at)
    if t == 43 and len(b) >= P + 56:
        key = struct.unpack_from('<I', b, P + 16)[0]
        v = P + 20
        if key in (1, 2):
            fix32(v + 32)
            # (the bytes after an object name's end: zeros, whatever they were)
            z = b.find(0, v, v + 32)
            if z >= 0:
                b[z:v + 32] = bytes(v + 32 - z)
        elif key == 4:
            fix64(v + 8)
            fix64(v + 24)
            fix32(v + 32)
        elif key not in (3,):
            fix64(v + 8)
            fix64(v + 16)
            b[v + 24:v + 36] = bytes(12)
    if t == 47 and len(b) >= P + 60:
        fix32(P)
        if b[P + 4:P + 9] == b'user-':
            b[P + 9:P + 11] = b'??'
        n = min(struct.unpack_from('<I', b, P + 56)[0], 16)
        for k in range(n):
            fix64(P + 60 + 8 * k)
    return bytes(b)


def show_diff(a, b):
    for k, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return f'#{k}: type {x[4]} len {len(x)}/{len(y)}\n         one   {x[:96].hex()}\n         other {y[:96].hex()}'
    return f'counts {len(a)} / {len(b)}'


def collect(prog, peer, secs=0.6):
    end = time.time() + secs
    while time.time() < end:
        prog.pump(0.03)
        peer.poll()
    return peer.take()


# ---- the scene, read back ---------------------------------------------------------------------

SUMMARY = '''
s = ""
for i in 0..count() {
 n = name(i)
 v = 0
 m = "-"
 if objtype(n) == 0 {
  v = everts(n)
  m = str(matof(n))
 }
 s = s + n + " " + str(round(get(n, "x") * 1000)) + " " + str(round(get(n, "y") * 1000)) + " " + str(round(get(n, "z") * 1000)) + " " + str(v) + " " + m + " " + str(get(n, "hidden")) + "|"
}
print(s)
'''


def chunks(d):
    out, o = [], 8
    while len(d) - o >= 8:
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        body = d[o + 8:o + 8 + size]
        if tag == b'ZCHK':
            tag = body[:4]
            body = zlib.decompress(body[8:], -15)
        out.append((tag, body))
        o += 8 + size
    return out


def canon(d):
    """A saved scene as what co-editing carries: each object (name, transform,
    colour, type, hidden) with its mesh (vertices, polygons) and material
    (index), the materials (their file part), the node trees."""
    if not d or d[:4] != b'BEEM':
        return None
    ch = chunks(d)
    meshes = [b for t, b in ch if t == b'MESH']
    objs = next((b for t, b in ch if t == b'OBJS'), b'\0\0\0\0')
    out = []
    n = struct.unpack_from('<I', objs)[0]
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        name = r[:32].split(b'\0')[0]
        typ, flags, mi = struct.unpack_from('<III', r, 72)
        mesh = meshes[mi] if typ == 0 and mi < len(meshes) else b''
        out.append((name, r[32:68], struct.unpack_from('<I', r, 68)[0], typ, flags & 0x200, mesh))
    keep = {t: b for t, b in ch if t in (b'MATS', b'OMAT', b'NTRE')}
    return out, keep


def save(prog, path):
    if os.path.exists(path):
        os.remove(path)
    prog.tool('run_operator', {'id': 'file.save_as', 'arg': path})
    end = time.time() + 20
    while not os.path.exists(path) and time.time() < end:
        prog.pump(0.05)
    prog.pump(0.1)
    return open(path, 'rb').read() if os.path.exists(path) else None


# ---- keyed connections (D6) -------------------------------------------------------------------

M64 = (1 << 64) - 1


def _rotl(x, b):
    return ((x << b) | (x >> (64 - b))) & M64


def siphash(data, k0, k1, word):
    """SipHash-2-4 of an 8-byte word and then the data (cosync's siphash)."""
    v0 = 0x736f6d6570736575 ^ k0
    v1 = 0x646f72616e646f6d ^ k1
    v2 = 0x6c7967656e657261 ^ k0
    v3 = 0x7465646279746573 ^ k1

    def rnd():
        nonlocal v0, v1, v2, v3
        v0 = (v0 + v1) & M64; v1 = _rotl(v1, 13); v1 ^= v0; v0 = _rotl(v0, 32)
        v2 = (v2 + v3) & M64; v3 = _rotl(v3, 16); v3 ^= v2
        v0 = (v0 + v3) & M64; v3 = _rotl(v3, 21); v3 ^= v0
        v2 = (v2 + v1) & M64; v1 = _rotl(v1, 17); v1 ^= v2; v2 = _rotl(v2, 32)

    def mix(x):
        nonlocal v0, v3
        v3 ^= x; rnd(); rnd(); v0 ^= x

    b = struct.pack('<Q', word) + bytes(data)
    n = len(b)
    for i in range(0, n - n % 8, 8):
        mix(struct.unpack_from('<Q', b, i)[0])
    mix(int.from_bytes(b[n - n % 8:], 'little') | ((n & 0xff) << 56))
    v2 ^= 0xff
    for _ in range(4):
        rnd()
    return v0 ^ v1 ^ v2 ^ v3


KDF0 = struct.unpack('<Q', b'BeeModel')[0]
KDF1 = struct.unpack('<Q', b'co.key!!')[0]


class Keyed:
    """A keyed connection's two keys and counters (the session key, both nonces)."""

    def __init__(self, phrase, nour, nth):
        p = phrase.encode()
        k0, k1 = siphash(p, KDF0, KDF1, 0), siphash(p, KDF0, KDF1, 1)
        lo, hi = sorted((nour, nth))
        d = struct.pack('<QQ', lo, hi)
        self.k0, self.k1 = siphash(d, k0, k1, 1), siphash(d, k0, k1, 2)
        self.nour, self.nth, self.sctr, self.rctr = nour, nth, 0, 0

    def tag_out(self, m):
        m = struct.pack('<I', struct.unpack_from('<I', m)[0] + 8) + m[4:]
        w = self.sctr | ((1 << 63) if self.nour < self.nth else 0)
        self.sctr += 1
        return m + struct.pack('<Q', siphash(m[4:], self.k0, self.k1, w))

    def check_in(self, m):
        n = struct.unpack_from('<I', m)[0]
        w = self.rctr | ((1 << 63) if self.nth < self.nour else 0)
        if n < 15 or siphash(m[4:n - 4], self.k0, self.k1, w) != struct.unpack_from('<Q', m, n - 4)[0]:
            return None
        self.rctr += 1
        return struct.pack('<I', n - 8) + m[4:n - 4]


# =================================================================================================
def s_words():
    print('  -- console words, tools, costat / cohash --')
    o, p = Prog('a'), Prog('b')
    port_o, port_p, dead = free_port(), free_port(), free_port()
    while port_p == port_o:
        port_p = free_port()
    calls = [
        ('op_co_key', {}), ('op_co_key', {'arg': 'short'}), ('op_co_key', {'arg': '   off'}),
        ('op_co_key', {'arg': 'correct horse'}), ('op_co_key', {'arg': 'off'}),
        ('op_co_leave', {}), ('op_co_follow', {'arg': 'off'}), ('op_co_follow', {'arg': 'bob'}),
        ('op_co_follow', {'arg': '1'}), ('op_co_follow', {'arg': '-3'}),
        ('op_co_agent', {'arg': 'on'}), ('op_co_agent', {'arg': 'off'}),
        ('op_co_join', {'arg': 'nowhere'}), ('op_co_join', {'arg': '127.0.0.1'}),
        ('op_co_join', {'arg': '127.0.0.1:%d' % dead}), ('op_co_join', {'arg': '1.2.3:5'}),
        ('op_co_join', {'arg': ' 127.0.0.1:%d' % dead}), ('op_co_join', {'arg': 'localhost:%d' % dead}),
        ('op_co_host', {'arg': 'x'}), ('op_co_host', {'arg': '-'}), ('op_co_leave', {}),
    ]
    bad = []
    for name, args in calls:
        a, b = o.tool(name, args), p.tool(name, args)
        if a != b or a[0] is None:
            bad.append((name, args, a, b))
        pump_all([o, p], 2)
    check(not bad, f'{len(calls)} operator calls through MCP: two BeeModels give the same replies and console words', bad[:3])
    # hosting: the port number said back (each on its own port)
    a = o.tool('op_co_host', {'arg': '%d.7 extra' % port_o})
    b = p.tool('op_co_host', {'arg': '%d.7 extra' % port_p})
    check(a[0] == 'ok\n> Host Co-Editing\n  co-editing: hosting on %d' % port_o and b[0] == 'ok\n> Host Co-Editing\n  co-editing: hosting on %d' % port_p,
          'co.host 7462.7 extra: hosting on the port (its leading number), the words the same', (a, b))
    a = o.tool('op_co_follow', {'arg': 'user-01'})
    b = p.tool('op_co_follow', {'arg': 'user-01'})
    check(a == b, 'co.follow of a peer not seen: the same words', (a, b))
    so = o.q('print(costat(0), costat(1), costat(2), costat(3), costat(7), costat(10), costat(-1))')
    sp = p.q('print(costat(0), costat(1), costat(2), costat(3), costat(7), costat(10), costat(-1))')
    check(so == sp == '1 0 3 0 0 0 0', f'costat in a session: in, no connections, 3 objects, no peers, not following ({so} / {sp})')
    a = o.tool('op_co_leave', {})
    b = p.tool('op_co_leave', {})
    check(a == b, 'co.leave: the same words', (a, b))
    so = o.q('print(costat(0), costat(2), costat(8), costat(9), cohash())')
    sp = p.q('print(costat(0), costat(2), costat(8), costat(9), cohash())')
    check(so == sp == '0 0 0 0 cbf29ce484222325', f'after leaving: no session, an empty document: FNV\'s basis ({so} / {sp})')
    a, b = o.q('print(costat(4) > 0, costat(6) > 0, costat(6) < 32768, costat(6) % 2)'), p.q('print(costat(4) > 0, costat(6) > 0, costat(6) < 32768, costat(6) % 2)')
    check(a == b == '1 1 1 1', f'operations made are kept after leaving; the peer id is odd, below 32768 ({a} / {b})')
    ro, rp = o.call('tools/list'), p.call('tools/list')
    to = {t['name']: t for t in ro['result']['tools'] if t['name'].startswith('op_co_')}
    tp = {t['name']: t for t in rp['result']['tools'] if t['name'].startswith('op_co_')}
    check(to == tp and len(to) == 6, f'the six co-editing tools listed alike ({sorted(tp)})')
    # co.key new: 20 letters in fives, from an alphabet without look-alikes
    a, b = o.tool('op_co_key', {'arg': 'new'})[0], p.tool('op_co_key', {'arg': 'new'})[0]
    pat = r'^ok\n> Session Key\.\.\.\n  co-editing: session key: [a-km-np-z2-9]{5}(-[a-km-np-z2-9]{5}){3}$'
    check(bool(re.match(pat, a or '')) and bool(re.match(pat, b or '')), f'co.key new: a key of 20 letters shown once ({b!r})')
    # an empty argument: the usage
    b = p.tool('op_co_join', {'arg': ''})
    check(b[0] is not None and p.alive() and p.q('print(costat(0))') == '0', f'co.join with an empty argument: no session, still answering ({(b[0] or "").splitlines()[-1:]})')
    o.kill()
    p.kill()


# =================================================================================================
RICH = ('add("sphere", "Ball", 2, 1, 0)\nmaterial("Gold")\nmatset("Gold", "base", 1, 0.8, 0.2)\nassign("Ball", "Gold")\n'
        'set("Light", "rx", 30)\nselect("Camera")\nop("object.hide")\nset("Cube", "sz", 2)\n'
        'op("logic.new", "Brain")\nop("logic.node", "Brain tick")\nop("logic.node", "Brain move")\n'
        'vmove("Cube", 2, 1, 1, 1)\nrename("Light", "abcdefghijklmnopqrstuvwxyzABCDEF")\n')


def host_stream(which, code):
    p = Prog(which)
    port = free_port()
    p.q(code + '\nop("co.host", "%d")' % port)
    p.pump(0.2)
    p.q('vmove("Cube", 3, 1, 2, 1)')            # (in the session: newer than its generation)
    p.pump(0.2)
    pe = Peer(port)
    pe.send(hello(0x1235))
    msgs = collect(p, pe, 1.0)
    st = p.q('print(costat(1), costat(2), costat(4), costat(5))')
    p.kill()
    pe.close()
    return msgs, st


def s_host():
    print('  -- a host\'s HELLO and document, twice, byte for byte --')
    for label, code in (('the default scene', ''), ('a sphere with a material, a turned light, a hidden camera, a scaled cube, a logic graph', RICH)):
        mo, so = host_stream('a', code)
        mp, sp = host_stream('b', code)
        no = [norm(m, peer_of(mo)) for m in mo]
        np_ = [norm(m, peer_of(mp)) for m in mp]
        types = sorted(set(m[4] for m in mo))
        check(len(no) > 10 and no == np_, f'{label}: {len(no)} messages (types {types}), hosted twice: the same bytes', show_diff(no, np_))
        check(so == sp, f'... and the counts after (connections, objects, operations made, applied: {sp})', (so, sp))


# =================================================================================================
def ts(c, peer=0x1235):
    return (c << 16) | peer


CUBE_V = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
CUBE_P = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (2, 3, 7, 6), (1, 2, 6, 5), (0, 4, 7, 3)]


def gen_payload(eid, t, verts, polys, uv=False):
    pos = b''.join(struct.pack('<3f', *v) for v in verts)
    poff, loops, o = [0], [], 0
    for p in polys:
        loops += p
        o += len(p)
        poff.append(o)
    rest = struct.pack('<%dI' % len(poff), *poff) + struct.pack('<%dI' % len(loops), *loops)
    if uv:
        rest += b''.join(struct.pack('<2f', (i % 4) * 0.25, (i // 4) * 0.1) for i in range(len(loops)))
    return struct.pack('<QQQIIII', eid, t, t, len(verts), len(polys), len(loops), 1 if uv else 0) + pos + rest


def reg(eid, t, key, val):
    return struct.pack('<QQI', eid, t, key) + val.ljust(36, b'\0')


def xf(loc, rot=(0, 0, 0), scl=(1, 1, 1)):
    return struct.pack('<9f', *loc, *rot, *scl)


def crafted():
    """A document as a host would send it (a test peer's, peer 0x1235)."""
    O = 0x1235
    n = [0]

    def m(t, pl):
        n[0] += 1
        return msg(t, O, n[0], pl)

    out = [hello(O, 0)]
    a, b, c, d = ts(1), ts(5), ts(9), ts(13)
    # a cube mesh with UVs, then one vertex newer than its generation
    out += [m(41, struct.pack('<QQQI', a, ts(2), 0, 0)), m(43, reg(a, ts(3), 1, b'Box')), m(43, reg(a, ts(3), 3, xf((1, 2, 3), (0.5, 0, 0))))]
    out += [m(43, reg(a, ts(3), 5, struct.pack('<I', 0x336699))), m(43, reg(a, ts(4), 2, b'Steel'))]
    out += [m(44, gen_payload(a, ts(4), CUBE_V, CUBE_P, uv=True))]
    out += [m(45, struct.pack('<QQQIII', a, ts(4), ts(20), 1, 6, 1) + struct.pack('<3f', 2, 2, 2))]
    # a light after it, hidden
    out += [m(41, struct.pack('<QQQI', b, ts(6), a, 1)), m(43, reg(b, ts(7), 1, b'Lamp')), m(43, reg(b, ts(7), 3, xf((0, 5, 0)))),
            m(43, reg(b, ts(7), 4, struct.pack('<I', 0x200)))]
    # a camera, then deleted (a tombstone kept)
    out += [m(41, struct.pack('<QQQI', c, ts(10), b, 2)), m(43, reg(c, ts(11), 1, b'Gone')), m(42, struct.pack('<QQ', c, ts(12)))]
    # a delete before its ADD, then the ADD (older): stays deleted
    out += [m(42, struct.pack('<QQ', d, ts(15))), m(41, struct.pack('<QQQI', d, ts(14), a, 0)), m(43, reg(d, ts(14), 1, b'Late'))]
    # a register older than the one taken: left as it is
    out += [m(43, reg(a, ts(2), 3, xf((9, 9, 9))))]
    # an element after the cube as the light is, newer: before it (RGA)
    f = ts(21)
    out += [m(41, struct.pack('<QQQI', f, ts(22), a, 2)), m(43, reg(f, ts(23), 1, b'Cam2')), m(43, reg(f, ts(23), 3, xf((0, 0, 7))))]
    # a material
    vals = struct.pack('<15f', 0.2, 0.3, 0.4, 1, 0.25, 0.5, 1.45, 0, 1, 1, 1, 0, 0, 0.03, 1)
    out += [m(46, b'Steel'.ljust(32, b'\0') + struct.pack('<Q', ts(8)) + vals)]
    # a node tree: two nodes, the second linked from the first
    tree = b'Logic'.ljust(32, b'\0')
    tail = bytes(480)
    out += [m(48, tree + struct.pack('<QI', ts(16), 1)), m(49, tree + struct.pack('<QI', ts(16), 1) + tail)]
    n1, n2 = ts(17), ts(18)
    out += [m(50, tree + struct.pack('<QQQ', n1, n1, 0)), m(50, tree + struct.pack('<QQQ', n2, n2, n1))]
    node1 = struct.pack('<I', 1) + bytes(68)
    node2 = struct.pack('<I', 2) + bytes(68)
    out += [m(52, tree + struct.pack('<QQ', n1, ts(19)) + node1 + bytes(27))]
    out += [m(52, tree + struct.pack('<QQ', n2, ts(19)) + node2 + struct.pack('<QQQ', n1, 0, 0) + b'\0\0\0')]
    n3 = ts(24)     # a node at the head too, newer: first
    out += [m(50, tree + struct.pack('<QQQ', n3, n3, 0)), m(52, tree + struct.pack('<QQ', n3, ts(25)) + struct.pack('<I', 3) + bytes(68) + bytes(24) + b'\0\0\0')]
    return out


JOIN_STEPS = [
    'move("Box", 4, 0, 0)', 'rename("Lamp", "Light2")', 'set("Box", "rz", 45)', 'set("Box", "sx", 3)',
    'select("Box")\nop("object.hide")', 'op("object.reveal")',
    'material("Red")\nmatset("Red", "base", 1, 0, 0)\nassign("Box", "Red")', 'matset("Steel", "metallic", 0.75)',
    'vmove("Box", 3, 0, 0, 9)', 'vmove("Box", 0, 1, 1, 1)\nvmove("Box", 1, 2, 1, 1)\nvmove("Box", 4, 3, 1, 1)',
    'vmove("Box", 2, vpos("Box", 2, 0), vpos("Box", 2, 1), vpos("Box", 2, 2))\nmove("Box", 4, 0, 1)', 'UNDO', 'add("cube", "C2", 1, 1, 1)', 'add("cylinder", "Cyl", 0, 2, 0)\ndelete("C2")',
    'select("Box")\nop("object.modifier_add", "subsurf")\nop("object.modifier_apply", "0")',
    'op("logic.node", "Logic spawn")', 'select("Cyl")\nop("object.duplicate")', 'set("Box", "color", 0xff8800)',
    'add("cube", "C3", 2, 2, 2)', 'UNDO', 'AGENT',
]


def join_run(which):
    L = Listener()
    p = Prog(which)
    p.q('op("co.join", "127.0.0.1:%d")' % L.port)
    pe = None
    for _ in range(50):
        p.pump(0.03)
        pe = L.accept()
        if pe:
            break
    out = {'first': collect(p, pe, 0.6)}
    pe.send(b''.join(crafted()))   # (in one piece: taken in one tick by both, else what a tick
                                   #  between its messages sees - a register before the material's
                                   #  values - becomes operations of its own, at any point)
    out['built'] = collect(p, pe, 1.0)
    out['scene'] = p.q(SUMMARY)
    out['hash'] = p.q('print(cohash())')
    out['bee'] = save(p, os.path.join(T, 'join_%s.bee' % which))
    pe.take()
    for k, code in enumerate(JOIN_STEPS):
        if code == 'UNDO':
            p.tool('undo')                      # (the last group's records backwards)
        elif code == 'AGENT':
            p.tool('op_co_agent', {'arg': 'on'})   # (the agent's operations and presence)
            p.tool('op_create_cube')
        else:
            p.q(code)
        out['step%d' % k] = collect(p, pe, 0.4)
    out['end'] = p.q(SUMMARY)
    out['hash2'] = p.q('print(cohash())')
    out['stat'] = p.q('print(costat(1), costat(2), costat(3), costat(4), costat(5), costat(9))')
    p.kill()
    pe.close()
    L.close()
    return out


def s_join():
    print('  -- a joiner: the scene it builds, the operations it sends (twice: the same) --')
    o, p = join_run('a'), join_run('b')
    po, pp = peer_of(o['first']), peer_of(p['first'])
    no = [norm(m, po) for m in o['first']]
    np_ = [norm(m, pp) for m in p['first']]
    check(len(no) >= 1 and no == np_, f'joining: its HELLO (and an empty document) the same ({len(no)} messages)', show_diff(no, np_))
    check(o['scene'] == p['scene'] and 'Box' in p['scene'] and 'Late' not in p['scene'] and 'Gone' not in p['scene'],
          f'the crafted document builds the same scene ({p["scene"]})', (o['scene'], p['scene']))
    check(o['hash'] == p['hash'], f'... the same document hash ({p["hash"]})', (o['hash'], p['hash']))
    co_, cp = canon(o['bee']), canon(p['bee'])
    check(co_ is not None and co_ == cp, '... and the same saved scene (objects, meshes, materials, node trees)', None if co_ == cp else [x[:2] for x in (co_ or [[]])[0]][:4])
    no = [norm(m, po) for m in o['built']]
    np_ = [norm(m, pp) for m in p['built']]
    check(no == np_, f'what it sends back after building it: the same ({len(no)} messages, types {sorted(set(m[4] for m in no))})',
          show_diff(no, np_) + '\n' + '\n'.join('         ' + m[:80].hex() for m in no + [b'--'] + np_))
    bad = []
    total = 0
    for k, code in enumerate(JOIN_STEPS):
        no = [norm(m, po) for m in o['step%d' % k]]
        np_ = [norm(m, pp) for m in p['step%d' % k]]
        total += len(no)
        if no != np_ or not no:
            bad.append((code, show_diff(no, np_)))
    check(not bad, f'{len(JOIN_STEPS)} edits (move, rename, turn, scale, hide, materials, a vertex, adds, deletes, a new topology, a node, a duplicate, a colour): {total} operations the same bytes', bad[:2])
    check(o['end'] == p['end'] and o['end'].count('|') == 6, f'the scenes after them the same ({p["end"]})', (o['end'], p['end']))
    check(o['stat'] == p['stat'], f'the counts (connections, objects, peers, made, applied, the undo log\'s bytes: {p["stat"]})', (o['stat'], p['stat']))


# =================================================================================================
TWO_STEPS = [
    ('a', 'set("Ball", "x", 1)'), ('b', 'set("Ball", "y", 2)'),
    ('a', 'vmove("Cube", 0, -2, -2, -2)'), ('b', 'vmove("Cube", 1, 3, 3, 3)'),
    ('b', 'add("cube", "N1", 1, 2, 3)\nrename("Light", "Lamp")'), ('a', 'add("cylinder", "N2", 0, 0, 1)\ndelete("Camera")'),
    ('b', 'select("N1")\nop("object.modifier_add", "subsurf")\nop("object.modifier_apply", "0")'),
    ('a', 'material("Red")\nmatset("Red", "base", 1, 0, 0)\nassign("N2", "Red")'),
    ('b', 'select("Cube")\nop("object.hide")'),
    ('a', 'op("logic.new", "Shared")\nop("logic.node", "Shared tick")'),
    ('b', 'op("logic.node", "Shared move")'), ('a', 'op("tree.node_set", "Shared 2 4 1")'),
    ('b', 'set("N2", "rx", 15)\nmatset("Red", "roughness", 0.2)'),
]


def two_run(host, join):
    a, b = Prog(host), Prog(join)
    P = {'a': a, 'b': b}
    port = free_port()
    a.q('add("sphere", "Ball", 2, 1, 0)\nmaterial("Gold")\nmatset("Gold", "base", 1, 0.8, 0.2)\nassign("Ball", "Gold")\n'
        'op("co.host", "%d")' % port)
    r = {'host9': a.q('print(costat(9))')}
    pump_all([a, b], 3)
    b.q('op("co.join", "127.0.0.1:%d")' % port)
    pump_all([a, b], 10)
    r['join'] = (a.q('print(cohash())'), b.q('print(cohash())'), a.q(SUMMARY), b.q(SUMMARY))
    for who, code in TWO_STEPS:
        P[who].q(code)
        pump_all([a, b], 8)
    r['hash'] = (a.q('print(cohash())'), b.q('print(cohash())'))
    r['sum'] = (a.q(SUMMARY), b.q(SUMMARY))
    r['stat'] = (a.q('print(costat(1), costat(2), costat(3), costat(4), costat(5), costat(9))'),
                 b.q('print(costat(1), costat(2), costat(3), costat(4), costat(5), costat(9))'))
    d = tempfile.mkdtemp(dir=T)
    r['bee'] = (save(a, d + '/a.bee'), save(b, d + '/b.bee'))
    # out of the session: the scene's own undo
    a.q('op("co.leave")')
    b.q('op("co.leave")')
    pump_all([a, b], 3)
    und = []
    for k in range(3):
        a.tool('undo')
        b.tool('undo')
        pump_all([a, b], 2)
        und.append((a.q(SUMMARY), b.q(SUMMARY)))
    r['undo'] = und
    a.kill()
    b.kill()
    return r


def s_two():
    print('  -- two peers in one session --')
    k = ('a', 'b')
    r = two_run(*k)
    tag = 'a hosts, b joins'
    check(r['join'][0] == r['join'][1] and r['join'][2] == r['join'][3] and 'Ball' in r['join'][2],
          f'{tag}: the joiner has the host\'s scene and document ({r["join"][0]})', r['join'])
    check(r['hash'][0] == r['hash'][1], f'{tag}: {len(TWO_STEPS)} edits, each taken by the other: one document ({r["hash"][0]})', r['hash'])
    check(r['sum'][0] == r['sum'][1] and r['sum'][0].count('|') >= 5, f'{tag}: the same scene on both', r['sum'])
    ca, cb = canon(r['bee'][0]), canon(r['bee'][1])
    check(ca is not None and ca == cb, f'{tag}: both peers\' saved .bee files the same (decoded)', None)
    check(r['host9'] == '0', f'{tag}: hosting puts nothing in the co-editing undo log (the starting scene is no edit to undo: {r["host9"]} bytes)')
    sa, sb = r['stat'][0].split(), r['stat'][1].split()
    check(len(sa) == len(sb) == 6 and sa[:2] == sb[:2] == ['1', sa[1]] and int(sa[1]) >= 5, f'{tag}: the counts: one connection each, as many objects ({r["stat"]})', r['stat'])
    check(len(set(r['undo'])) >= 2, f'{tag}: out of the session, three undos of the scene\'s own history step back', r['undo'])


# =================================================================================================
def chain_run(kinds, seed, rounds):
    ps = [Prog(k) for k in kinds]
    a, b, c = ps
    port_a, port_b = free_port(), free_port()
    while port_b == port_a:
        port_b = free_port()
    a.q('add("sphere", "Ball", 2, 1, 0)\nop("co.host", "%d")' % port_a)
    pump_all(ps, 3)
    b.q('op("co.join", "127.0.0.1:%d")' % port_a)
    pump_all(ps, 6)
    b.q('op("co.host", "%d")' % port_b)
    pump_all(ps, 2)
    c.q('op("co.join", "127.0.0.1:%d")' % port_b)
    pump_all(ps, 10)
    hashes = lambda: tuple(p.q('print(cohash())') for p in ps)
    h0 = hashes()
    # one property at once on three peers: one winner
    for k, p in enumerate(ps):
        p.q('set("Ball", "x", %d)' % (k + 1))
    pump_all(ps, 10)
    xs = tuple(p.q('print(get("Ball", "x"))') for p in ps)
    rnd = random.Random(seed)
    for k in range(rounds):
        p = rnd.choice(ps)
        r = rnd.random()
        i = rnd.randrange(1000)
        x, y, z = (round(rnd.uniform(-6, 6), 2) for _ in range(3))
        pick = 'n = name(%d %% count())\n' % i
        if r < 0.3:
            code = pick + 'move(n, %s, %s, %s)' % (x, y, z)
        elif r < 0.4:
            code = pick + 'rename(n, "F%d")' % rnd.randrange(50)
        elif r < 0.5:
            code = 'material("M%d")\nmatset("M%d", "base", %s, 0.5, 0.5)\n' % (i % 5, i % 5, abs(x) / 6) + pick + 'assign(n, "M%d")' % (i % 5)
        elif r < 0.55:
            code = pick + 'select(n)\nop("object.hide")'
        elif r < 0.7:
            code = 'add("%s", "N%d", %s, %s, %s)' % (rnd.choice(['cube', 'sphere', 'cylinder']), i, x, y, z)
        elif r < 0.78:
            code = 'if count() > 6 {\n' + pick + 'delete(n)\n}'
        elif r < 0.95:
            code = pick + 'vmove(n, %d, %s, %s, %s)' % (i % 6, x, y, z)
        else:
            code = pick + 'select(n)\nop("object.modifier_add", "subsurf")\nop("object.modifier_apply", "0")'
        p.q(code)
        if rnd.random() < 0.25:
            for q in ps:
                q.pump(0.005)
    stable = False
    h = None
    for _ in range(40):
        pump_all(ps, 4)
        h = hashes()
        if h[0] == h[1] == h[2]:
            pump_all(ps, 4)
            if hashes() == h:
                stable = True
                break
    sums = tuple(p.q(SUMMARY) for p in ps)
    d = tempfile.mkdtemp(dir=T)
    bees = [canon(save(p, d + '/%d.bee' % k)) for k, p in enumerate(ps)]
    alive = all(p.alive() for p in ps)
    for p in ps:
        p.kill()
    return h0, xs, stable, h, sums, bees, alive


def s_chain():
    print('  -- three peers in a chain, edits at once --')
    for kinds, seed in ((('a', 'b', 'c'), 151), (('a', 'b', 'c'), 152)):
        h0, xs, stable, h, sums, bees, alive = chain_run(kinds, seed, ROUNDS)
        tag = '-'.join(kinds) + f' (seed {seed})'
        check(h0[0] == h0[1] == h0[2], f'{tag}: the last joiner (through the middle one) has the host\'s document ({h0[0]})', h0)
        check(xs[0] == xs[1] == xs[2] and xs[0] in ('1', '2', '3'), f'{tag}: one property set at once on three peers: one value wins everywhere ({xs})')
        check(stable and h[0] == h[1] == h[2], f'{tag}: {ROUNDS} random edits on all three at once: one document ({h})', h)
        check(sums[0] == sums[1] == sums[2] and sums[0].count('|') > 3, f'{tag}: ... and the same scene everywhere ({sums[0].count("|")} objects)', sums)
        check(bees[0] is not None and bees[0] == bees[1] == bees[2], f'{tag}: ... and the same saved .bee files (decoded)')
        check(alive, f'{tag}: all three still running')


# =================================================================================================
def s_undo():
    print('  -- undo per author --')
    res = {}
    for kinds in (('a', 'b'),):
        a, b = Prog(kinds[0]), Prog(kinds[1])
        port = free_port()
        a.q('add("sphere", "Ball", 2, 1, 0)\nop("co.host", "%d")' % port)
        pump_all([a, b], 3)
        b.q('op("co.join", "127.0.0.1:%d")' % port)
        pump_all([a, b], 10)
        b9 = b.q('print(costat(9))')
        a.q('move("Ball", 5, 1, 0)')
        pump_all([a, b], 4)
        b.q('move("Cube", 0, 4, 0)')
        pump_all([a, b], 6)
        logs = (a.q('print(costat(9))'), b.q('print(costat(9))'))
        b.keyz()                                # B: Ctrl+Z - B's own move
        pump_all([a, b], 10)
        r = {'b_undo': (a.q('print(get("Ball", "x"), get("Cube", "y"))'), b.q('print(get("Ball", "x"), get("Cube", "y"))'))}
        b.keyz(shift=True)                      # B: Ctrl+Shift+Z - again
        pump_all([a, b], 10)
        r['b_redo'] = (a.q('print(get("Ball", "x"), get("Cube", "y"))'), b.q('print(get("Ball", "x"), get("Cube", "y"))'))
        a.keyz()                                # A: Ctrl+Z - A's move, not B's
        pump_all([a, b], 10)
        r['a_undo'] = (a.q('print(get("Ball", "x"), get("Cube", "y"))'), b.q('print(get("Ball", "x"), get("Cube", "y"))'))
        r['logs'] = (logs, b9, b.q('print(costat(9), costat(8))'))
        r['hash'] = (a.q('print(cohash())'), b.q('print(cohash())'))
        r['undo_tool'] = b.tool('undo')
        pump_all([a, b], 6)
        r['after_tool'] = (a.q('print(get("Ball", "x"), get("Cube", "y"))'), b.q('print(get("Ball", "x"), get("Cube", "y"))'))
        # nothing left of B's: undo again changes nothing, no error
        b.keyz()
        b.keyz()
        pump_all([a, b], 6)
        r['empty'] = (a.q('print(get("Ball", "x"), get("Cube", "y"), count())'), b.q('print(get("Ball", "x"), get("Cube", "y"), count())'))
        # a grab under way on B while A's edit comes in; B's Esc cancels the grab
        # only; then B's Ctrl+Z (its last own edit: the move before)
        b.q('select("Cube")')
        pump_all([a, b], 3)
        shot0 = b.shot(0.3)
        b.mouse(640, 300)
        b.f.key(34)                             # G
        b.pump(0.1)
        for k in range(5):
            b.mouse(640 + 20 * k, 300 - 10 * k)
            b.pump(0.05)
        a.q('move("Ball", 7, 1, 0)')
        pump_all([a, b], 8)
        mid = b.q('print(get("Ball", "x"))')
        b.f.key(1)                              # Esc
        pump_all([a, b], 8)
        r['grab'] = (mid, a.q('print(get("Ball", "x"), get("Cube", "x"), get("Cube", "y"))'), b.q('print(get("Ball", "x"), get("Cube", "x"), get("Cube", "y"))'))
        shot1 = b.shot(0.3)
        r['drawn'] = shot0.tobytes() != shot1.tobytes()
        res[kinds] = r
        a.kill()
        b.kill()
    for kinds, r in res.items():
        tag = f'{kinds[0]} hosts, {kinds[1]} joins'
        check(r['b_undo'][0] == r['b_undo'][1] == '5 1', f'{tag}: B\'s Ctrl+Z takes back B\'s move only, on both peers ({r["b_undo"]})')
        check(r['b_redo'][0] == r['b_redo'][1] == '5 4', f'{tag}: B\'s Ctrl+Shift+Z: B\'s move again ({r["b_redo"]})')
        check(r['a_undo'][0] == r['a_undo'][1] == '2 4', f'{tag}: A\'s Ctrl+Z takes back A\'s move, B\'s stays ({r["a_undo"]})')
        check(r['hash'][0] == r['hash'][1], f'{tag}: one document after undo and redo ({r["hash"][0]})')
        check(r['after_tool'][0] == r['after_tool'][1] and r['empty'][0] == r['empty'][1] and r['empty'][0].endswith(' 4'),
              f'{tag}: the MCP undo tool and undo with nothing left: both peers alike, no object lost ({r["after_tool"]}, {r["empty"]})', (r['after_tool'], r['empty']))
        check(r['grab'][0] == '7' and r['grab'][1] == r['grab'][2] and r['grab'][1].startswith('7 ') and r['drawn'],
              f'{tag}: B grabbing while A\'s move comes in: B\'s Esc cancels the grab only, A\'s move stays, both peers alike ({r["grab"]}); B\'s view shows A\'s move', r['grab'])


# =================================================================================================
def s_agent():
    print('  -- the agent peer --')
    res = {}
    for kinds in (('a', 'b'),):
        a, b = Prog(kinds[0]), Prog(kinds[1])
        port = free_port()
        a.q('op("co.host", "%d")' % port)
        pump_all([a, b], 3)
        b.q('op("co.join", "127.0.0.1:%d")' % port)
        pump_all([a, b], 8)
        b.tool('op_co_agent', {'arg': 'on'})
        a.q('move("Cube", 0, 3, 0)')
        pump_all([a, b], 6)
        b.tool('op_create_cube')                # the agent (B's tools) adds,
        pump_all([a, b], 8)
        r = {'n1': (a.q('print(count())'), b.q('print(count())')), 'peers': a.q('print(costat(3))'),
             'agent': b.q('print(costat(8) > 0)'), 'logs': b.q('print(costat(8), costat(9))')}
        b.tool('op_edit_undo')                  # then undoes its own
        pump_all([a, b], 10)
        r['n2'] = (a.q('print(count(), get("Cube", "y"))'), b.q('print(count(), get("Cube", "y"))'))
        r['hash'] = (a.q('print(cohash())'), b.q('print(cohash())'))
        res[kinds] = r
        a.kill()
        b.kill()
    for kinds, r in res.items():
        tag = f'{kinds[0]} hosts, {kinds[1]} is the agent\'s'
        check(r['n1'][0] == r['n1'][1] == '4' and r['agent'] == '1', f'{tag}: the agent\'s cube appears on both; it is in the agent\'s undo log ({r["n1"]})')
        check(int(r['peers']) >= 2, f'{tag}: the host sees the user and the agent as peers ({r["peers"]})')
        check(r['n2'][0] == r['n2'][1] == '3 3', f'{tag}: the agent\'s undo takes its cube back, the user\'s move stays ({r["n2"]})')
        check(r['hash'][0] == r['hash'][1], f'{tag}: one document ({r["hash"][0]})')


# =================================================================================================
KEY = 'correct horse battery'


def keyed_peer(which):
    p = Prog(which)
    port = free_port()
    p.q('op("co.key", "%s")\nop("co.host", "%d")' % (KEY, port))
    pe = Peer(port)
    first = collect(p, pe, 0.4)
    peer = peer_of(first)
    nth = struct.unpack_from('<Q', first[0], 19)[0] if first and len(first[0]) >= 27 else 0
    k = Keyed(KEY, 0x1111222233334444, nth)
    pe.send(hello(0x1235, 1, 0x1111222233334444))
    got = collect(p, pe, 0.5)
    auth = k.check_in(got[0]) if got else None
    before = p.q('print(costat(1))')
    pe.send(k.tag_out(msg(53, 0x1235, 2, b'')))
    state = collect(p, pe, 0.8)
    plain = [k.check_in(m) for m in state]
    # a tagged ADD from us is taken
    pe.send(k.tag_out(msg(41, 0x1235, 3, struct.pack('<QQQI', ts(50), ts(51), 0, 0))))
    pe.send(k.tag_out(msg(43, 0x1235, 4, reg(ts(50), ts(52), 1, b'Keyed'))))
    pe.send(k.tag_out(msg(44, 0x1235, 5, gen_payload(ts(50), ts(52), CUBE_V, CUBE_P))))
    collect(p, pe, 0.5)
    took = p.q('print(exists("Keyed"), costat(1))')
    # a wrong tag: refused
    bad = bytearray(k.tag_out(msg(41, 0x1235, 6, struct.pack('<QQQI', ts(60), ts(61), 0, 0))))
    bad[-1] ^= 1                                 # (one bit of its tag)
    pe.send(bytes(bad))
    collect(p, pe, 0.4)
    after = p.q('print(costat(1))')
    p.kill()
    pe.close()
    return [norm(first[0], peer)[:19]] if first else [], auth and auth[4], before, [norm(m, peer) if m else None for m in plain], took, after


def s_key():
    print('  -- session keys --')
    o, p = keyed_peer('a'), keyed_peer('b')
    check(o[0] == p[0] != [] and o[1] == p[1] == 53, 'a keyed HELLO carries a nonce; the AUTH back checks out under the key (a test peer\'s SipHash)', (o[:2], p[:2]))
    check(o[2] == p[2] == '0', 'nothing of the document before our AUTH (no connection in yet)', (o[2], p[2]))
    check(len(p[3]) > 10 and None not in p[3] and o[3] == p[3], f'after it: {len(p[3])} messages, every tag checking out, the same bytes twice', show_diff(o[3], p[3]) if None not in o[3] + p[3] else 'a tag did not check out')
    check(o[4] == p[4] == '1 1', f'tagged operations from the peer are taken ({p[4]})', (o[4], p[4]))
    check(o[5] == p[5] == '0', 'a message with a wrong tag: the peer refused', (o[5], p[5]))
    for kinds in (('a', 'b'),):
        a, b, c, d = Prog(kinds[0]), Prog(kinds[1]), Prog('c'), Prog('d')
        port = free_port()
        a.q('op("co.key", "%s")\nadd("sphere", "Ball", 2, 1, 0)\nop("co.host", "%d")' % (KEY, port))
        b.q('op("co.key", "%s")' % KEY)
        pump_all([a, b], 3)
        b.q('op("co.join", "127.0.0.1:%d")' % port)
        pump_all([a, b], 10)
        h = (a.q('print(cohash())'), b.q('print(cohash())'))
        b.q('set("Ball", "z", 3)')
        pump_all([a, b], 8)
        z = a.q('print(get("Ball", "z"))')
        c.q('op("co.key", "another pass phrase")\nop("co.join", "127.0.0.1:%d")' % port)
        d.q('op("co.join", "127.0.0.1:%d")' % port)
        pump_all([a, b, c, d], 12)
        got = (c.q('print(count(), costat(1))'), d.q('print(count(), costat(1))'), a.q('print(costat(1))'))
        tag = f'{kinds[0]} hosts with a key, {kinds[1]} joins with it'
        check(h[0] == h[1] and z == '3', f'{tag}: the same document, edits both ways ({h[0]})', h)
        check(got == ('0 0', '0 0', '1'), f'{tag}: a peer with another key and a peer with none are refused and get nothing ({got})')
        for x in (a, b, c, d):
            x.kill()


# =================================================================================================
def s_pres():
    print('  -- presence, following --')
    for kinds in (('a', 'b'),):
        a, b = Prog(kinds[0]), Prog(kinds[1])
        port = free_port()
        a.q('add("sphere", "Ball", 2, 1, 0)\nop("co.host", "%d")' % port)
        pump_all([a, b], 3)
        b.q('op("co.join", "127.0.0.1:%d")' % port)
        pump_all([a, b], 8)
        b.q('select("Ball")\nview(40, 30, 9, 1, 0, 0)')
        pump_all([a, b], 10)
        seen = (a.q('print(costat(3))'), b.q('print(costat(3))'))
        a.q('view(30, 25, 12, 0, 0, 0)')       # (the host's presence went out before the joiner came)
        pump_all([a, b], 10)
        seen2 = b.q('print(costat(3))')
        f1 = a.tool('op_co_follow', {'arg': '1'})
        b.q('view(70, 20, 7, 0, 1, 0)')
        pump_all([a, b], 12)
        fol = a.q('print(round(viewinfo(0)), round(viewinfo(1)), round(viewinfo(2)), round(viewinfo(4)), costat(7))')
        a.tool('op_co_follow', {'arg': 'off'})
        b.q('view(10, 10, 5, 0, 0, 0)')
        pump_all([a, b], 10)
        unf = a.q('print(round(viewinfo(0)), costat(7))')
        tag = f'{kinds[0]} hosts, {kinds[1]} joins'
        check(seen == ('1', '0') and seen2 == '1', f'{tag}: the host sees the joiner\'s presence; the joiner the host\'s once it changes ({seen}, then {seen2})')
        check(f1[0] is not None and f1[0].startswith('ok\n> Follow Peer\n  co-editing: following 1') and fol == '70 20 7 1 1', f'{tag}: co.follow 1: the host\'s view on the joiner\'s ({fol})', (f1, fol))
        check(unf == '70 0', f'{tag}: co.follow off: the view stays where it was ({unf})')
        a.kill()
        b.kill()
    # the drawing: a test peer's selection, camera and cursor
    masks = {}
    for w in ('port',):
        p = Prog(w)
        p.tool('run_operator', {'id': 'area.maximize'})
        port = free_port()
        p.q('op("co.host", "%d")' % port)
        pe = Peer(port)
        pe.send(hello(0x1235))
        ids = {}
        for m in collect(p, pe, 0.6):
            t, o, num, pl = parse(m)
            if t == 43 and struct.unpack_from('<I', pl, 16)[0] == 1:
                ids[pl[20:52].split(b'\0')[0].decode()] = struct.unpack_from('<Q', pl, 0)[0]
        before = p.shot()
        pe.send(pres(0x1235, 2, 'user-35', cam=(0.6, 0.3, 9, 1, 0, 0), cur=(2, 1, 0), sel=(ids.get('Cube', 0),)))
        pe.send(pres(0x1236 | 0x8000, 3, 'agent', sel=(ids.get('Light', 0), ids.get('Cube', 0))))
        collect(p, pe, 0.4)
        after = p.shot()
        masks[w] = set()
        for y in range(80, 770):
            for x in range(0, 1280):
                if before.getpixel((x, y)) != after.getpixel((x, y)):
                    masks[w].add((x, y))
        p.kill()
        pe.close()
    mp = masks['port']
    check(len(mp) > 200, f'a peer\'s selection (a mesh\'s edges in its colour), its camera and its cursor drawn: {len(mp)} pixels changed')


# =================================================================================================
def s_ui():
    print('  -- the Versions editor\'s Collaboration section, the status bar --')
    shots = {}
    for w in ('port',):
        p = Prog(w)
        p.tool('run_operator', {'id': 'area.type_versions'})
        p.tool('run_operator', {'id': 'area.maximize'})
        off = p.shot()
        port = free_port()
        p.q('op("co.host", "%d")' % port)
        pe = Peer(port)
        pe.send(hello(0x1235))
        pe.send(pres(0x1235, 2, 'user-35', cam=(0.5, 0.3, 9, 1, 0, 0)))
        collect(p, pe, 0.5)
        on = p.shot()
        shots[w] = (off, on, p, pe)
    from PIL import Image

    def editor_x(img):
        # the Versions heading's first accent pixel: the column's left
        for x in range(5, 400):
            for y in range(88, 106):
                c = img.getpixel((x, y))
                if c[0] > 200 and 120 < c[1] < 200 and c[2] < 80:
                    return x
        return None

    def rows(img, x0, y0, y1, w=300):
        return [tuple(img.getpixel((x0 + dx, y)) for dx in range(w)) for y in range(y0, y1)]

    def follow_box(img, x_lo, y_lo, y_hi):
        pts = [(x, y) for y in range(y_lo, y_hi) for x in range(x_lo, img.width)
               if img.getpixel((x, y)) == (54, 59, 69)]
        if not pts:
            return None
        xs = [x for x, _ in pts]
        ys = [y for _, y in pts]
        return min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1

    res = {}
    for w, (off, on, p, pe) in shots.items():
        x = editor_x(on)
        res[w] = dict(x=x, off=rows(off, x, 140, 260, 1240) if x else None, on=rows(on, x, 140, 260, 1240) if x else None,
                      follow=follow_box(on, x + 400, 178, 202) if x else None,
                      bg=[on.getpixel((1180 + dx, 790)) for dx in range(100)], bg_off=[off.getpixel((1180 + dx, 790)) for dx in range(100)])
    q = res['port']
    check(q['x'] is not None, f'the Versions editor\'s column found (its heading at x {q["x"]})')
    check(q['x'] is not None and q['off'] != q['on'], 'in a session the Collaboration section shows something else than out of one')
    fp = q['follow']
    check(fp is not None and fp[2] > 20 and fp[3] > 10, f'a Follow button at the peer\'s row\'s right ({fp})')
    check(q['bg'] != q['bg_off'], 'the status bar\'s "Co-editing" chip at its right end in a session, not out of one')
    # Follow clicked in the window: co.follow 1, then off
    off, on, p, pe = shots['port']
    if fp:
        p.click(fp[0] + 30, fp[1] + 8)
        for _ in range(6):
            p.pump(0.05)
            pe.poll()
        f1 = p.q('print(costat(7))')
        p.click(fp[0] + 30, fp[1] + 8)
        for _ in range(6):
            p.pump(0.05)
            pe.poll()
        f2 = p.q('print(costat(7))')
        check(f1 == '1' and f2 == '0', f'Follow clicked: following the peer; clicked again: not ({f1}, {f2})')
    for w, (off, on, p, pe) in shots.items():
        p.kill()
        pe.close()


# =================================================================================================
def s_fuzz():
    print('  -- damaged, partial, oversized, reordered messages; vanishing and too many peers --')
    p = Prog('port')
    port = free_port()
    p.q('op("co.host", "%d")' % port)
    rnd = random.Random(7)
    O = 0x2345
    sent = 0

    def peer():
        pe = Peer(port)
        pe.send(hello(O))
        return pe

    good = peer()
    collect(p, good, 0.3)
    rss0 = int(open('/proc/%d/statm' % p.f.proc.pid).read().split()[1]) * 4096
    cases = []
    # every type, short by every amount
    for t in list(range(40, 54)) + [0, 39, 54, 255]:
        for n in (0, 1, 3, 7, 10, 20, 27, 40, 55, 99):
            cases.append(msg(t, O, 0, bytes(rnd.randrange(256) for _ in range(n))))
    # counts that do not fit their bytes; a range past the vertices (wrapping); an element after itself
    e = ts(900, O)
    cases.append(msg(44, O, 0, struct.pack('<QQQIIII', e, ts(901, O), ts(901, O), 0xffffffff, 3, 7, 1) + bytes(64)))
    cases.append(msg(44, O, 0, struct.pack('<QQQIIII', e, ts(902, O), ts(902, O), 8, 0x40000000, 24, 0) + bytes(96)))
    cases.append(msg(44, O, 0, gen_payload(e, ts(903, O), CUBE_V, [(0, 1, 9)])))   # a loop past the vertices
    cases.append(msg(41, O, 0, struct.pack('<QQQI', e, ts(904, O), e, 0)))       # after itself
    cases.append(msg(43, O, 0, reg(e, ts(905, O), 1, b'Loopy')))
    cases.append(msg(45, O, 0, struct.pack('<QQQIII', e, ts(903, O), ts(906, O), 1, 0xffffffff, 2) + bytes(24)))
    cases.append(msg(45, O, 0, struct.pack('<QQQIII', e, ts(903, O), ts(906, O), 0x7fffffff, 0, 1) + bytes(12)))
    cases.append(msg(47, O, 0, struct.pack('<I', O) + bytes(52) + struct.pack('<I', 0xffffffff)))
    cases.append(msg(52, O, 0, b'T'.ljust(32, b'\0') + struct.pack('<QQ', e, e) + bytes(99)))
    cases.append(msg(50, O, 0, b'T'.ljust(32, b'\0') + struct.pack('<QQQ', e, e, e)))   # a node after itself
    cases.append(msg(46, O, 0, b'\xff' * 32 + struct.pack('<Q', ts(907, O)) + bytes(60)))
    for k, c in enumerate(cases):
        c = bytearray(c)
        struct.pack_into('<I', c, 7, 1000 + k)   # (each its own number)
        good.send(bytes(c))
        sent += 1
        if k % 40 == 0:
            p.pump(0.02)
    # duplicates and reordered: a REG before its ADD, the same ADD twice, a DEL before the ADD
    f = ts(950, O)
    good.send(msg(43, O, 2001, reg(f, ts(952, O), 1, b'Early')))
    good.send(msg(44, O, 2002, gen_payload(f, ts(952, O), CUBE_V, CUBE_P)))
    good.send(msg(41, O, 2003, struct.pack('<QQQI', f, ts(951, O), 0, 0)))
    good.send(msg(41, O, 2003, struct.pack('<QQQI', f, ts(951, O), 0, 0)))
    good.send(msg(41, O, 2004, struct.pack('<QQQI', f, ts(951, O), 0, 0)))
    collect(p, good, 0.5)
    early = p.q('print(exists("Early"))')
    # partial messages, peers vanishing mid-message, an oversized length
    for k in range(12):
        x = peer()
        m = msg(43, O, 3000 + k, reg(f, ts(960 + k, O), 1, b'Half'))
        x.send(m[:rnd.randrange(1, len(m))])
        p.pump(0.02)
        x.close()
    x = peer()
    x.send(struct.pack('<I', 0xfffffff0) + bytes(1000))
    p.pump(0.05)
    x.close()
    x = peer()
    x.send(struct.pack('<I', 64 * 1024 * 1024 + 100) + b'\x2b' + bytes(200000))
    p.pump(0.1)
    x.close()
    # random bytes from a fresh peer, then gone
    for k in range(6):
        x = Peer(port)
        x.send(bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 4000))))
        p.pump(0.03)
        x.close()
    # too many peers: eight at most; the ninth and tenth are closed
    many = [peer() for _ in range(9)]
    for _ in range(8):
        p.pump(0.05)
        for x in many:
            x.poll()
    conns = p.q('print(costat(1))')
    closed = sum(1 for x in many if x.closed)
    # a relay reaches them all: an operation from the good peer
    g = ts(970, O)
    good.send(msg(41, O, 4000, struct.pack('<QQQI', g, ts(971, O), 0, 2)))
    good.send(msg(43, O, 4001, reg(g, ts(972, O), 1, b'Relayed')))
    end = time.time() + 1.5
    got = 0
    while time.time() < end:
        p.pump(0.03)
        got = 0
        for x in many:
            x.poll()
            got += any(m[4] == 43 and b'Relayed' in m for m in x.msgs)
    for x in many:
        x.close()
    good.poll()
    echo = [m for m in good.msgs if struct.unpack_from('<H', m, 5)[0] == O]
    collect(p, good, 0.3)
    alive = p.alive()
    reply = p.q('print(exists("Relayed"), exists("Half"), costat(0))')
    rss1 = int(open('/proc/%d/statm' % p.f.proc.pid).read().split()[1]) * 4096
    # a clean joiner gets the whole document
    o2 = Prog('port')
    o2.q('op("co.join", "127.0.0.1:%d")' % port)
    pump_all([p, o2], 12)
    hj = (p.q('print(cohash())'), o2.q('print(cohash())'))
    o2.kill()
    p.kill()
    good.close()
    check(alive and reply.startswith('1 '), f'{sent} damaged messages of every type and length, partial ones, vanishing peers, oversized lengths, random bytes: still running and answering ({reply})')
    check(early == '1', 'a register and a mesh before their element\'s ADD, the ADD twice: the object made once, named')
    check(conns == '8' and closed == 2, f'ten peers at once: eight in, the others closed ({conns} in, {closed} closed)')
    check(not echo, f'... and not back to the peer it came from ({len(echo)} came back)')
    check(got == 8 - 1 or got == 8, f'an operation from one peer relayed to the others ({got} of the {8 - 1} still in)')
    check(rss1 - rss0 < 512 * 1024 * 1024, f'memory: {rss0 >> 20} -> {rss1 >> 20} MiB')
    check(hj[0] == hj[1], f'a peer joining after all that gets the same document ({hj[0]})', hj)


# =================================================================================================
def main():
    print('  co-editing: %s' % BIN)
    for name, fn in (('words', s_words), ('host', s_host), ('join', s_join), ('two', s_two), ('chain', s_chain),
                     ('undo', s_undo), ('agent', s_agent), ('key', s_key), ('pres', s_pres), ('ui', s_ui), ('fuzz', s_fuzz)):
        if not section(name):
            continue
        try:
            fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            check(False, f'{name}: {type(e).__name__}: {e}')
        finally:
            for p in list(ALL):
                p.kill()
            for pe in list(PEERS):
                pe.close()
    check(not PANICS, 'BeeModel\'s stderr has no panic and no leak', PANICS[:1])


try:
    main()
finally:
    for p in list(ALL):
        p.kill()
    for pe in list(PEERS):
        pe.close()
    shutil.rmtree(T, True)
print('co-editing: fails', len(FAILS))
sys.exit(1 if FAILS else 0)
