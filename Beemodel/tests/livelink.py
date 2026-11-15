#!/usr/bin/env python3
"""The live link (link.zig, docs/LIVELINK.md): BeeModel in its fake
compositor, with its own temp HOME, XDG folders and MCP socket, serving on
127.0.0.1 ports picked free (or UNIX sockets in the test's temp dir), never
another address:

  wire     the bytes it sends to a reader written here: HELLO, the snapshot
           (every material, mesh and object), every kind of change as the
           protocol says (TICK first, OBJECT, DELETE, TRANSFORM, PROPERTY 1-4,
           MESH, MESH_DELTA, MATERIAL), undo, a new file, a late reader, a UNIX
           socket; names zero after their end
  ops      run_operator's replies for every argument form, livelink(k), --link
           without an address, --eval
  mirror   two mirrors of one server: their saved scenes the server's; undo
           in a mirror; the session ending; mirroring again; a chain
  limits   8 readers and the 9th let go, bad HELLOs, a HELLO in pieces, a
           reader that never says HELLO, readers that vanish
  back     backpressure: a reader that stops reading gets each object's latest
           place once it reads again
  fuzz     a fake server feeding its mirror damaged streams, peers sending junk
           or vanishing mid-message, many peers: no crash, no hang, memory
           bounded
  perf     latency and throughput (LL_REL: a release build; else BIN)
  look     the status bar's chip: there while serving and mirroring, gone after

    python3 tests/livelink.py BIN [runs=1]

BEE_CPU (default 12) pins BeeModel; LL_ONLY=wire,ops,... runs some sections;
LL_FUZZ (default 150) sets the fuzz's stream count.
"""
import json, os, random, re, shutil, signal, socket, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own, all five XDG folders)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
REL = os.environ.get('LL_REL', BIN)
CPU = int(os.environ.get('BEE_CPU', '12'))
ONLY = [x for x in os.environ.get('LL_ONLY', '').split(',') if x]
NFUZZ = int(os.environ.get('LL_FUZZ', '150'))
FAILS = []
T = tempfile.mkdtemp(prefix='bll-', dir='/tmp')   # (short: UNIX socket paths)
os.environ['TMPDIR'] = T
tempfile.tempdir = T
PROCS = []
SOCKS = []
PERF = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def section(name):
    return not ONLY or name in ONLY


def cleanup():
    for s in SOCKS:
        try:
            s.close()
        except OSError:
            pass
    for p in PROCS:
        try:
            if p.poll() is None:
                p.kill()
            p.wait(3)
        except Exception:
            pass
    shutil.rmtree(T, True)


def on_signal(*_):
    cleanup()
    os._exit(1)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)


# ---- the programs -------------------------------------------------------------------

def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Prog:
    """BeeModel in its fake compositor, an MCP client on its socket."""

    def __init__(self, which='port', binary=None, args=(), size=(1280, 800)):
        from wl_fake import Fake
        self.which = which
        self.home = tempfile.mkdtemp(prefix='h', dir=T)
        env = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0', 'BEEMODEL_AGENT_PERMISSION': 'files',
               'HOME': self.home, 'XDG_RUNTIME_DIR': self.home, 'XDG_CACHE_HOME': os.path.join(self.home, 'cache')}
        self.f = Fake(binary or BIN, size=size, env=env, args=args)
        PROCS.append(self.f.proc)
        self.f.until(lambda: self.f.frames > 0, 10)
        self.pid = self.f.proc.pid
        os.sched_setaffinity(self.pid, {CPU})
        self.pump(0.3)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(50):
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

    def call(self, method, params, timeout=20):
        self.rid += 1
        m = {'jsonrpc': '2.0', 'id': self.rid, 'method': method, 'params': params}
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
                if r.get('id') == self.rid:
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
            return r['result']['content'][0]['text']
        except (TypeError, KeyError, IndexError):
            return None

    def q(self, code):
        return self.tool('script_eval', {'code': code}) or ''

    def op(self, op, arg=None):
        a = {'id': op}
        if arg is not None:
            a['arg'] = arg
        return self.tool('run_operator', a)

    def save(self, name):
        p = os.path.join(self.home, name)
        self.op('file.save_as', p)
        self.pump(0.2)
        return open(p, 'rb').read() if os.path.exists(p) else None

    def image(self):
        from PIL import Image
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def rss_kb(self):
        try:
            for line in open('/proc/%d/status' % self.pid):
                if line.startswith('VmRSS:'):
                    return int(line.split()[1])
        except OSError:
            pass
        return -1

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            self.f.proc.kill()
            self.f.proc.wait(3)
        except Exception:
            pass


def pump_all(progs, n=8, t=0.03, readers=()):
    for _ in range(n):
        for p in progs:
            p.pump(t)
        for r in readers:
            r.read()


# ---- a reader that keeps every byte -------------------------------------------------

class Raw:
    def __init__(self, address, hello=True, role=1, rcvbuf=0):
        if address.startswith('unix:'):
            self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.s.connect(address[5:])
        else:
            host, port = address.rsplit(':', 1)
            assert host == '127.0.0.1'
            self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if rcvbuf:
                self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
            self.s.connect((host, int(port)))
        SOCKS.append(self.s)
        self.s.setblocking(False)
        self.data = b''
        self.closed = False
        self.arrived = []   # (bytes so far, local monotonic ns)
        if hello:
            self.send(hello_msg(role))

    def send(self, b):
        try:
            self.s.setblocking(True)
            self.s.sendall(b)
            self.s.setblocking(False)
        except OSError:
            self.closed = True

    def read(self):
        while True:
            try:
                c = self.s.recv(1 << 22)
                if c == b'':
                    self.closed = True
                    return
                self.data += c
                self.arrived.append((len(self.data), time.monotonic_ns()))
            except BlockingIOError:
                return
            except OSError:
                self.closed = True
                return

    def msgs(self):
        out, o = [], 0
        while o + 4 <= len(self.data):
            n = struct.unpack_from('<I', self.data, o)[0]
            if o + 4 + n > len(self.data):
                break
            out.append(self.data[o + 4:o + 4 + n])
            o += 4 + n
        return out

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def hello_msg(role=1, name=b'reader', version=1, magic=b'BEEL'):
    body = struct.pack('<B4sHHI32s', 1, magic, version, role, 0, name)
    return struct.pack('<I', len(body)) + body


NAMES = {1: 'HELLO', 2: 'SNAP_BEGIN', 3: 'SNAP_END', 4: 'TICK', 10: 'OBJECT', 11: 'DELETE',
         12: 'TRANSFORM', 13: 'PROPERTY', 20: 'MESH', 21: 'MESH_DELTA', 30: 'MATERIAL'}
NAME_AT = {10: 25, 30: 5}   # where a message's name[32] is (PROPERTY 1: 9)
PAD_BAD = [0]               # names with anything but 0 after their end


def name_span(m):
    if m and m[0] in NAME_AT:
        return NAME_AT[m[0]]
    if m and m[0] == 13 and len(m) >= 41 and struct.unpack_from('<I', m, 5)[0] == 1:
        return 9
    return None


def pad_check(ms):
    """Count the names with anything but 0 after their end."""
    for m in ms:
        at = name_span(m)
        if at is not None and len(m) >= at + 32:
            nm = m[at:at + 32]
            end = nm.find(b'\0')
            if end >= 0 and nm[end:] != b'\0' * (32 - end):
                PAD_BAD[0] += 1


def describe(m):
    t = m[0]
    s = NAMES.get(t, str(t))
    if t in (10, 11, 12, 13, 20, 21, 30) and len(m) >= 5:
        s += ' %d' % struct.unpack_from('<I', m, 1)[0]
    if t == 10:
        s += ' ' + m[25:57].split(b'\0')[0].decode('utf-8', 'replace')
    if t == 13:
        s += ' key %d' % struct.unpack_from('<I', m, 5)[0]
    if t == 20:
        s += ' nv=%d np=%d nl=%d uv=%d' % struct.unpack_from('<4I', m, 5)
    if t == 21:
        s += ' ranges=%d' % struct.unpack_from('<I', m, 5)[0]
    return s + ' (%d B)' % len(m)


def kinds(ms):
    return [m[0] for m in ms]


def prop_keys(ms):
    return [struct.unpack_from('<I', m, 5)[0] for m in ms if m[0] == 13 and len(m) >= 9]


def stream_ok(ms, label, need=(), never=(), cond=True, why=''):
    """A turn's messages: TICK first (when any), the kinds it needs, none it must not have."""
    pad_check(ms)
    ks = kinds(ms)
    ok = cond and all(k in ks for k in need) and not any(k in ks for k in never)
    if ms:
        ok = ok and ks[0] == 4 and all(k in NAMES for k in ks)
    elif need:
        ok = False
    check(ok, label + ' (%d messages: %s)%s' % (len(ms), ', '.join(sorted(set(NAMES.get(k, str(k)) for k in ks))) or 'none', why))
    if not ok:
        for x in ms[:40]:
            print('       ', describe(x))
    return ok


def snapshot(ms):
    """The messages from SNAP_BEGIN to SNAP_END: (complete, [messages])."""
    ks = kinds(ms)
    if 2 not in ks:
        return False, []
    a = ks.index(2)
    b = ks.index(3, a) if 3 in ks[a:] else None
    return b is not None, ms[a:(b + 1 if b is not None else len(ms))]


def scene_objs(p):
    """scene_summary's objects."""
    try:
        return json.loads(p.tool('scene_summary'))['objects']
    except (TypeError, ValueError, KeyError):
        return []


def snapshot_ok(ms, p, label):
    """A whole snapshot: an OBJECT for every object of the scene, a MESH for
    each mesh object."""
    done, sn = snapshot(ms)
    pad_check(sn)
    objs = scene_objs(p)
    n = len(objs)
    nm = len([o for o in objs if o.get('type') == 'mesh'])
    ks = kinds(sn)
    ok = done and n > 0 and ks.count(10) == n and ks.count(20) >= nm
    check(ok, '%s: %d objects, %d meshes: %d OBJECT, %d MESH, %d MATERIAL%s' % (label, n, nm, ks.count(10), ks.count(20), ks.count(30), '' if done else ', no SNAP_END'))
    return ok


# ---- .bee files compared as scenes ---------------------------------------------------

SKIP_CHUNKS = (b'THMB', b'WSPC')


def scene_of(data):
    cs = beefile.chunks(data)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = []
    for o in beefile.objects(data):
        mi = o['mesh']
        objs.append((o['name'], o['type'], o['flags'], o['loc'], o['rot'], o['scl'], o['color'], meshes[mi] if mi < len(meshes) else None))
    other = {}
    for t, b in cs:
        if t in SKIP_CHUNKS or t in (b'MESH', b'OBJS') or (t == b'ANIM' and not b):
            continue
        if t == b'MUVS':
            b = muvs_by_object(b, beefile.objects(data))
        other.setdefault(t, []).append(b)
    return objs, other


def muvs_by_object(c, objs):
    """MUVS's records (a mesh index, flags, loops, UVs, seams) by the objects
    whose meshes they are: the two writers number meshes in their own order."""
    owner = {}
    for o in objs:
        owner.setdefault(o['mesh'], o['name'])
    out, at = [], 0
    while len(c) - at >= 12:
        ix, flags, nl = struct.unpack_from('<3I', c, at)
        size = (nl * 8 if flags & 1 else 0) + ((nl + 3) // 4 * 4 if flags & 2 else 0)
        out.append((owner.get(ix, '?%d' % ix), flags, nl, c[at + 12:at + 12 + size]))
        at += 12 + size
    return sorted(out)


def bee_diff(a, b):
    """[] when the two files hold the same scene (objects with their meshes in
    order, every other chunk byte for byte but the thumbnail and the layout)."""
    if a is None or b is None:
        return ['a file missing: %s %s' % (a is None, b is None)]
    (oa, ca), (ob, cb) = scene_of(a), scene_of(b)
    d = []
    if len(oa) != len(ob):
        d.append('objects: %s vs %s' % ([x[0] for x in oa], [x[0] for x in ob]))
    for x, y in zip(oa, ob):
        if x != y:
            f = ['name', 'type', 'flags', 'loc', 'rot', 'scl', 'colour', 'mesh']
            d.append('object %s: %s' % (x[0], [k for k, u, v in zip(f, x, y) if u != v]))
    for t in sorted(set(ca) | set(cb)):
        if ca.get(t) != cb.get(t):
            d.append('chunk %s differs' % t.decode())
    return d


# ---- wire --------------------------------------------------------------------------------

PREP = ('add("sphere", "Ball", 2, 1, 0)\nmaterial("Gold")\nmatset("Gold", "base", 1, 0.8, 0.2)\n'
        'assign("Ball", "Gold")\nadd("cylinder", "Post", -2, 0, 1)\nset("Post", "rx", 0.3)')

STEPS = [
    ('nothing changed: nothing sent', ''),
    ('a move: TRANSFORM', 'move("Cube", 1, 2, 3)'),
    ('rotation and scale: TRANSFORM', 'set("Cube", "rx", 0.5)\nset("Cube", "sy", 2)'),
    ('a vertex: MESH_DELTA', 'vmove("Cube", 0, 0, 3, 0)'),
    ('vertices apart: MESH_DELTA of three runs', 'vmove("Ball", 5, 0, 1, 0)\nvmove("Ball", 6, 0, 1, 0)\nvmove("Ball", 40, 1, 0, 0)\nvmove("Ball", 400, 0, 0, 1)'),
    ('a new object: MESH, OBJECT', 'add("sphere", "Ball2", 4, 1, 0)'),
    ('a material assigned: PROPERTY 2, MATERIAL', 'material("Blue")\nmatset("Blue", "base", 0.1, 0.2, 0.9)\nassign("Ball2", "Blue")'),
    ('a material value: MATERIAL', 'matset("Gold", "roughness", 0.2)\nmatset("Blue", "metallic", 1)'),
    ('a modifier: the whole MESH', 'select("Ball")\nop("object.modifier_add", "subsurf")'),
    ('hidden: PROPERTY 3', 'select("Cube")\nop("object.hide")'),
    ('shown again: PROPERTY 3', 'set("Cube", "hidden", 0)'),
    ('a colour: PROPERTY 4', 'set("Post", "color", 16711680)'),
    ('a new name: PROPERTY 1', 'rename("Post", "Pillar")'),
    ('deleted: DELETE', 'delete("Ball2")'),
    ('a duplicate: MESH, OBJECT', 'select("Pillar")\nop("object.duplicate")'),
    ('a light and a camera: OBJECT without a mesh', 'op("create.light")\nop("create.camera")'),
    ('UVs: a vertex moved sends the whole MESH', 'select("Pillar.001")\nop("uv.unwrap")'),
    ('UVs: then a vertex', 'vmove("Pillar.001", 0, 0, 0.5, 0)'),
    ('twenty new objects in one turn', 'for i in 0..20 { add("cube", "M" + str(i), i, 0, 0) }'),
    ('twenty moves in one turn: one TICK', 'for i in 0..20 { set("M" + str(i), "y", 3) }'),
    ('twenty deleted', 'for i in 0..20 { delete("M" + str(i)) }'),
    ('the material unassigned: PROPERTY 2 = -1', 'select("Ball")\nop("material.assign", "none")'),
]


def deltas(ms):
    return [struct.unpack_from('<I', m, 5)[0] for m in ms if m[0] == 21]


def n_of(ms, k):
    return kinds(ms).count(k)


# what each step must send (the protocol's kinds: docs/LIVELINK.md), what it must not,
# and a test of its own
EXPECT = {
    'nothing changed: nothing sent': ((), (), lambda ms: not ms),
    'a move: TRANSFORM': ((12,), (20, 21, 10), None),
    'rotation and scale: TRANSFORM': ((12,), (20, 21, 10), None),
    'a vertex: MESH_DELTA': ((21,), (20,), None),
    'vertices apart: MESH_DELTA of three runs': ((21,), (20,), lambda ms: deltas(ms) == [3]),
    'a new object: MESH, OBJECT': ((20, 10), (), None),
    'a material assigned: PROPERTY 2, MATERIAL': ((13, 30), (), lambda ms: 2 in prop_keys(ms)),
    'a material value: MATERIAL': ((30,), (20, 21), None),
    'a modifier: the whole MESH': ((20,), (21,), None),
    'hidden: PROPERTY 3': ((13,), (), lambda ms: prop_keys(ms) == [3]),
    'shown again: PROPERTY 3': ((13,), (), lambda ms: prop_keys(ms) == [3]),
    'a colour: PROPERTY 4': ((13,), (), lambda ms: prop_keys(ms) == [4]),
    'a new name: PROPERTY 1': ((13,), (), lambda ms: prop_keys(ms) == [1]),
    'deleted: DELETE': ((11,), (10,), lambda ms: n_of(ms, 11) == 1),
    'a duplicate: MESH, OBJECT': ((20, 10), (), lambda ms: n_of(ms, 10) == 1),
    'a light and a camera: OBJECT without a mesh': ((10,), (20, 21), lambda ms: n_of(ms, 10) == 2),
    'UVs: a vertex moved sends the whole MESH': ((20,), (21,), None),
    'UVs: then a vertex': ((20,), (21,), None),
    'twenty new objects in one turn': ((10, 20), (), lambda ms: n_of(ms, 10) == 20 and n_of(ms, 4) == 1),
    'twenty moves in one turn: one TICK': ((12,), (10, 20), lambda ms: n_of(ms, 12) == 20 and n_of(ms, 4) == 1),
    'twenty deleted': ((11,), (10,), lambda ms: n_of(ms, 11) == 20),
    'the material unassigned: PROPERTY 2 = -1': ((13,), (), lambda ms: any(m[0] == 13 and struct.unpack_from('<I', m, 5)[0] == 2 and struct.unpack_from('<i', m, 9)[0] == -1 for m in ms)),
}


def turn(p, r, seen):
    pump_all([p], 8, readers=[r])
    ms = r.msgs()
    got = ms[seen[0]:]
    seen[0] = len(ms)
    return got


def s_wire():
    print('  -- wire: what it sends --', flush=True)
    p = Prog()
    p.q(PREP)
    port = free_port()
    r = p.op('link.serve', str(port))
    check(r is not None and 'serving on %d' % port in r, 'serves on 127.0.0.1:%d' % port)
    p.pump(0.2)
    rd = Raw('127.0.0.1:%d' % port)
    pump_all([p], 10, readers=[rd])
    b = rd.msgs()
    check(len(b) > 0 and b[0][0] == 1 and struct.unpack_from('<I', b[0], 9)[0] == p.pid and b[0][13:21] == b'BeeModel',
          'HELLO first: its pid, "BeeModel"')
    snapshot_ok(b, p, 'HELLO and the snapshot: every mesh and object')
    seen = [len(b)]
    for label, code in STEPS:
        if code:
            p.q(code)
        got = turn(p, rd, seen)
        need, never, test = EXPECT[label]
        stream_ok(got, label, need, never, test(got) if test else True)
    # undo and redo in the server: what they change goes out
    for label, tool in (('undo: the change taken back goes out', 'undo'), ('redo', 'redo')):
        p.tool(tool)
        got = turn(p, rd, seen)
        stream_ok(got, label, cond=len(got) > 1)
    # TICK: the clock of the turn the changes left in
    t0 = time.monotonic_ns()
    p.q('move("Cube", 2, 2, 2)')
    pump_all([p], 6, readers=[rd])
    t1 = time.monotonic_ns()
    ms = rd.msgs()[seen[0]:]
    seen[0] = len(rd.msgs())
    ticks = [struct.unpack_from('<Q', m, 1)[0] for m in ms if m[0] == 4]
    check(len(ticks) == 1 and t0 <= ticks[0] <= t1, 'TICK: CLOCK_MONOTONIC in ns, inside the step\'s time')
    # a new scene: every object deleted, the new ones with uids from 1 again
    n_before = len(scene_objs(p))
    p.op('file.new')
    got = turn(p, rd, seen)
    n_after = len(scene_objs(p))
    stream_ok(got, 'a new scene: DELETEs, the defaults again (uids taken again)', (11,), cond=n_of(got, 11) == n_before - n_after,
              why=' (%d objects, then %d)' % (n_before, n_after))
    p.q(PREP + '\nmaterial("Blue")\nfor i in 0..5 { add("cube", "N" + str(i), i, 2, 0) }\nselect("Ball")\nop("object.modifier_add", "subsurf")')
    turn(p, rd, seen)
    # a late reader: the whole snapshot of the scene as it is now
    late = Raw('127.0.0.1:%d' % port)
    pump_all([p], 10, readers=[late, rd])
    snapshot_ok(late.msgs(), p, 'a reader joining later: the snapshot of the scene as it is')
    got = rd.msgs()[seen[0]:]
    stream_ok(got, 'the first reader meanwhile: nothing')
    seen[0] = len(rd.msgs())
    st = p.q('print(livelink(0), livelink(1), livelink(3), livelink(4), livelink(5), livelink(6), livelink(7))').split()
    check(len(st) == 7 and st[0] == '1' and st[1] == '2' and st[3] == '0' and all(float(x) >= 0 for x in st),
          'livelink(0, 1, 3, 4, 5, 6, 7): serving, 2 peers, messages, not mirroring, received, held back, snapshots (%s)' % ' '.join(st))
    sent = p.q('print(livelink(2))').strip()
    check(sent and float(sent) >= len(rd.data) + len(late.data) - 2 * 48, 'livelink(2): the bytes sent (%s; the readers got %d)' % (sent, len(rd.data) + len(late.data)))
    # a parent moved by a script: its child's TRANSFORM too
    p.q('op("object.parent_set", "Post Cube")')
    turn(p, rd, seen)
    p.q('move("Cube", 5, 5, 5)')
    got = turn(p, rd, seen)
    uids = set(struct.unpack_from('<I', m, 1)[0] for m in got if m[0] == 12)
    stream_ok(got, 'a parent moved by a script: its child\'s TRANSFORM too', (12,), cond=len(uids) == 2)
    for x in (late, rd):
        x.close()
    pump_all([p], 6)
    check(p.q('print(livelink(1))') == '0\n', 'readers gone: livelink(1) 0')
    # a UNIX socket
    path = os.path.join(p.home, 'll.sock')
    r = p.op('link.serve', 'unix:' + path)
    check(r is not None and r.endswith('serving on ' + path), 'serves on a UNIX socket')
    p.pump(0.2)
    rd = Raw('unix:' + path)
    pump_all([p], 10, readers=[rd])
    snapshot_ok(rd.msgs(), p, 'the snapshot over a UNIX socket')
    seen = [len(rd.msgs())]
    p.q('move("Ball", 9, 9, 9)\nvmove("Cube", 1, 1, 1, 1)')
    got = turn(p, rd, seen)
    stream_ok(got, 'changes over a UNIX socket', (12, 21))
    p.op('link.stop')
    p.pump(0.2)
    rd.read()
    check(rd.closed, 'link.stop lets the readers go')
    check(not os.path.exists(path), 'the UNIX socket removed at link.stop')
    # a material removed, then a reader: its snapshot stops at the list
    port = free_port()
    p.op('link.serve', str(port))
    p.q('material("Gone")')
    p.pump(0.2)
    r1 = Raw('127.0.0.1:%d' % port)
    pump_all([p], 6, readers=[r1])
    p.op('material.remove', 'Gone')
    p.pump(0.2)
    r2 = Raw('127.0.0.1:%d' % port)
    pump_all([p], 8, readers=[r1, r2])
    ms = r2.msgs()
    sb = [m for m in ms if m[0] == 2]
    nm = len([m for m in ms if m[0] == 30])
    n1 = len([m for m in r1.msgs()[:r1.msgs().index(next(x for x in r1.msgs() if x[0] == 3))] if m[0] == 30])
    check(p.alive() and sb and ms[-1][0] == 3 and struct.unpack_from('<I', sb[0], 9)[0] == nm == n1 - 1,
          'a reader after a material was removed: the snapshot with the materials there are (%d of %d)' % (nm, n1))
    r1.close()
    r2.close()
    check(PAD_BAD[0] == 0, 'the names: zero after their end (%d not)' % PAD_BAD[0])
    p.close()


# ---- operators: the console words ------------------------------------------------------

def s_ops():
    print('  -- operators: the console words, livelink(k) --', flush=True)
    port = free_port()
    port2 = free_port()
    lis = socket.socket()
    SOCKS.append(lis)
    lis.bind(('127.0.0.1', port2))
    lis.listen(8)     # (something that accepts and says nothing)
    upath = os.path.join(T, 'u.sock')
    # (op, arg, what livelink(0) serving and livelink(4) mirroring must be after it, None: either)
    seq = [('link.serve', str(port), 1, 0), ('link.serve', 'abc', None, 0), ('link.serve', ' %d' % port, None, 0), ('link.serve', '%d extra words' % port, None, 0),
           ('link.serve', '%d.9' % port, None, 0), ('link.serve', 'unix:' + upath, 1, 0), ('link.serve', 'unix:%s and more' % upath, None, 0),
           ('link.serve', 'lan abc', None, 0), ('link.serve', 'unix:/nonexistent-dir/x.sock', None, 0), ('link.stop', None, 0, 0), ('link.stop', None, 0, 0),
           ('link.connect', '127.0.0.1:1', 0, 0), ('link.connect', None, 0, 0), ('link.connect', 'garbage words', 0, 0),
           ('link.connect', '1.2.3:4', 0, 0), ('link.connect', '999.0.0.1:5', 0, 0), ('link.connect', 'localhost', 0, 0),
           ('link.connect', 'unix:/nonexistent-dir/x', 0, 0), ('link.connect', None, 0, 0),
           ('link.connect', 'localhost:%d' % port2, 0, None), ('link.disconnect', None, 0, 0), ('link.disconnect', None, 0, 0),
           ('link.connect', '127.0.0.1:%d' % port2, 0, None), ('link.connect', '127.0.0.1:%d' % port2, 0, None), ('link.disconnect', None, 0, 0)]
    stats = 'print(livelink(0), livelink(1), livelink(4), livelink(5), livelink(8), livelink(-1), livelink(0.9))'
    p = Prog()
    for op, arg, serving, mirroring in seq:
        r = p.op(op, arg)
        p.pump(0.05)
        st = p.q(stats).split()
        try:
            v = [float(x) for x in st]
        except ValueError:
            v = []
        ok = r is not None and len(v) == 7 and all(x == x and abs(x) < 1e12 for x in v)
        ok = ok and (serving is None or v[0] == serving) and (mirroring is None or v[2] == mirroring)
        check(ok, '%s %s: %s (livelink: %s)' % (op, arg if arg is not None else '(none)', (r or 'None').replace('\n', ' / '), ' '.join(st)))
        try:
            c, _ = lis.accept() if select_ready(lis) else (None, None)
            if c:
                SOCKS.append(c)
        except OSError:
            pass
    check(p.alive(), 'still running')
    p.close()
    try:
        os.unlink(upath)
    except OSError:
        pass
    lis.close()
    # --link without an address; --eval
    h = tempfile.mkdtemp(prefix='h', dir=T)
    e = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'c'))
    e.pop('WAYLAND_DISPLAY', None)
    e.pop('DISPLAY', None)
    r = subprocess.run([BIN, '--link'], env=e, capture_output=True, timeout=20)
    pp = free_port()
    r2 = subprocess.run([BIN, '--eval', 'op("link.serve", "%d")\nprint(livelink(0), livelink(1), livelink(4))\nop("link.stop")\nprint(livelink(0))' % pp],
                        env=e, capture_output=True, timeout=20)
    check(r.returncode > 0 and r.stderr.strip() and b'panic' not in r.stderr, '--link without an address: refused with a word: %r, exit %d' % (r.stderr[-200:], r.returncode))
    check(r2.returncode == 0 and r2.stdout.split()[-4:] == [b'1', b'0', b'0', b'0'], '--eval with link.serve: serving, then not: %r' % r2.stdout)


def select_ready(s):
    import select
    r, _, _ = select.select([s], [], [], 0)
    return bool(r)


# ---- mirrors -------------------------------------------------------------------------------

def summary(p):
    """scene_summary's objects as the link carries them: name, type, place,
    rotation, scale, colour, hidden, the evaluated vertices and faces (no
    selection: each its own)."""
    out = []
    for o in scene_objs(p):
        n = o['name']
        ev = p.q('print(get("%s", "color"), get("%s", "hidden"))' % (n, n)).split()
        if o['type'] == 'mesh':
            ev += p.q('print(everts("%s"), efaces("%s"))' % (n, n)).split()
        out.append((o['name'], o['type'], tuple(round(x, 3) for x in o['location']), tuple(round(x, 2) for x in o['rotation_deg']),
                    tuple(round(x, 3) for x in o['scale']), ev))
    return out


def mirror_diff(m, s, name=None):
    """[] when the mirror shows the server's scene (scene_summary's objects)."""
    a, b = summary(s), summary(m)
    if a == b:
        return []
    d = ['objects %s / %s' % ([x[0] for x in a], [x[0] for x in b])] if [x[0] for x in a] != [x[0] for x in b] else []
    return d + ['%s: %s / %s' % (x[0], x[1:], y[1:]) for x, y in zip(a, b) if x != y][:3]


def s_mirror():
    print('  -- mirrors: beemodel --link, link.connect --', flush=True)
    s = Prog()
    port = free_port()
    s.q(PREP)
    s.op('link.serve', str(port))
    s.pump(0.2)
    mo = Prog(args=['--link', '127.0.0.1:%d' % port])
    mp = Prog()
    mp.op('link.connect', '127.0.0.1:%d' % port)
    ms = [mo, mp]
    pump_all([s] + ms, 12)
    look = 'print(count(), livelink(4), livelink(5))'
    lo, lp = mo.q(look), mp.q(look)
    check(lo.split()[:2] == lp.split()[:2] and lo.split()[1:2] == ['1'] and lo.split()[0] == s.q('print(count())').strip(),
          'two mirrors (--link, link.connect): mirroring, the server\'s count (%s / %s)' % (lo.strip(), lp.strip()))
    for m, nm in ((mo, '--link'), (mp, 'link.connect')):
        d = mirror_diff(m, s, 'snap.bee')
        check(not d, 'the %s mirror: the server\'s scene after the snapshot %s' % (nm, d))
    steps = [('moves, a vertex, a new object, a rotation',
              'move("Ball", -3, 2, 1)\nvmove("Ball", 7, 1, 1, 1)\nadd("cube", "Box", 5, 0.5, 5)\nset("Box", "ry", 0.5)'),
             ('a modifier, hidden, renamed, deleted, a material value, a colour',
              'select("Ball")\nop("object.modifier_add", "subsurf")\nselect("Cube")\nop("object.hide")\nrename("Light", "Lamp")\n'
              'delete("Camera")\nmatset("Gold", "roughness", 0.2)\nset("Post", "color", 255)'),
             ('UVs, a duplicate, a new material, a light',
              'select("Box")\nop("uv.unwrap")\nop("object.duplicate")\nmaterial("Red")\nmatset("Red", "base", 1, 0, 0)\nassign("Box", "Red")\nop("create.light")'),
             ('a parent moved', 'op("object.parent_set", "Post Box")\nmove("Box", 1, 1, 1)')]
    for label, code in steps:
        s.q(code)
        pump_all([s] + ms, 10)
        d = mirror_diff(mo, s, 'm.bee')
        d2 = bee_diff(mo.save('m.bee'), mp.save('m.bee'))
        check(not d and not d2, '%s: the mirrors the server\'s scene %s %s' % (label, d, d2))
    # undo in a mirror: nothing of the link's to undo
    uo, up = mo.tool('undo'), mp.tool('undo')
    check(uo is not None and 'nothing to undo' in uo and up is not None and 'nothing to undo' in up, 'undo in a mirror: %r' % uo)
    # a change of the mirror's own, a remote one, then undo: the own one taken back
    base = mo.save('base.bee')
    for m in ms:
        m.q('add("cube", "Mine", 0, 5, 0)\nmaterial("Local")\nmaterial("Local2")')
    s.q('move("Ball", 4, 4, 4)')
    pump_all([s] + ms, 10)
    d = bee_diff(mo.save('own.bee'), mp.save('own.bee'))
    names = [o['name'] for o in beefile.objects(mo.save('own.bee'))]
    check(not d and 'Mine' in names, 'a mirror\'s own object and a remote move, in both mirrors %s' % d)
    uo, up = mo.tool('undo'), mp.tool('undo')
    pump_all([s] + ms, 4)
    after = mo.save('undo.bee')
    names = [o['name'] for o in beefile.objects(after)]
    ball = [o for o in beefile.objects(after) if o['name'] == 'Ball']
    # (a remote change is no step of its own: undo goes back past it, to the mirror's last own step)
    check('Mine' not in names and 'Ball' in names and not bee_diff(after, mp.save('undo.bee')),
          'undo in the mirror (%r): its own object gone, both mirrors alike' % (up or '').replace('\n', ' / '))
    ro, rp = mo.tool('redo'), mp.tool('redo')
    pump_all([s] + ms, 4)
    check('Mine' in [o['name'] for o in beefile.objects(mo.save('redo.bee'))] and not bee_diff(mo.save('redo.bee'), mp.save('redo.bee')), 'redo: it is back')
    # the server stops: the session ends
    s.op('link.stop')
    pump_all([s] + ms, 8)
    lo, lp = mo.q('print(livelink(4))'), mp.q('print(livelink(4))')
    check(lo == lp == '0\n', 'the server stops: neither mirrors now')
    # mirroring again (link.connect): a new snapshot replaces the scene
    port = free_port()
    s.op('link.serve', str(port))
    s.pump(0.2)
    for m in ms:
        r = m.op('link.connect', '127.0.0.1:%d' % port)
    pump_all([s] + ms, 12)
    d = mirror_diff(mo, s, 'again.bee')
    check(not d and (r or '').endswith('mirroring 127.0.0.1:%d' % port), 'serving again, link.connect: the server\'s scene %s' % d)
    # link.disconnect: the scene stays
    for m in ms:
        m.op('link.disconnect')
    y0 = mo.q('print(get("Ball", "y"))')
    s.q('move("Ball", 0, 7, 0)')
    pump_all([s] + ms, 6)
    go = mo.q('print(get("Ball", "y"), livelink(4))')
    check(go.split() == [y0.strip(), '0'], 'link.disconnect: the scene stays as it was (%s)' % go.strip())
    for x in [s] + ms:
        x.close()
    # a mirror of a mirror serving (a chain)
    a = Prog()
    pa = free_port()
    a.q(PREP)
    a.op('link.serve', str(pa))
    a.pump(0.2)
    b = Prog(args=['--link', '127.0.0.1:%d' % pa])
    pump_all([a, b], 10)
    pb = free_port()
    b.op('link.serve', str(pb))
    b.pump(0.2)
    c = Prog(args=['--link', '127.0.0.1:%d' % pb])
    pump_all([a, b, c], 12)
    a.q('move("Ball", 1, 9, 1)\nvmove("Cube", 2, 0, 2, 0)\nadd("sphere", "Late", 0, 0, 3)')
    pump_all([a, b, c], 12)
    d = mirror_diff(c, a, 'chain.bee')
    check(not d and not bee_diff(b.save('chain.bee'), c.save('chain.bee')), 'a chain: server -> mirror serving -> mirror, the same scene %s' % d)
    for x in (a, b, c):
        x.close()


# ---- limits ---------------------------------------------------------------------------------

def s_limits():
    print('  -- limits: peers, HELLOs --', flush=True)
    if True:
        p = Prog()
        port = free_port()
        p.op('link.serve', str(port))
        p.pump(0.2)
        out = {}
        rs = [Raw('127.0.0.1:%d' % port) for _ in range(9)]
        pump_all([p], 10, readers=rs)
        out['nine'] = [(len(r.msgs()) > 0, r.closed) for r in rs]
        out['peers'] = p.q('print(livelink(1))')
        for r in rs:
            r.close()
        pump_all([p], 6)
        out['after'] = p.q('print(livelink(1))')
        bad = {}
        for nm, msg in (('version 2', hello_msg(version=2)), ('magic', hello_msg(magic=b'BEEX')),
                        ('type 5', b'\x2d\0\0\0\x05' + hello_msg()[5:]), ('length 44', b'\x2c\0\0\0' + hello_msg()[4:]),
                        ('junk', os.urandom(64)), ('role 7', hello_msg(role=7))):
            r = Raw('127.0.0.1:%d' % port, hello=False)
            r.send(msg)
            pump_all([p], 6, readers=[r])
            bad[nm] = (r.closed, len(r.msgs()))
            r.close()
        out['bad'] = bad
        # a HELLO a byte at a time
        r = Raw('127.0.0.1:%d' % port, hello=False)
        for ch in hello_msg():
            r.send(bytes([ch]))
            p.pump(0.005)
        pump_all([p], 8, readers=[r])
        out['pieces'] = [x[0] for x in r.msgs()][-1:]
        r.close()
        # silent (no HELLO): nothing sent; it holds a place
        r = Raw('127.0.0.1:%d' % port, hello=False)
        pump_all([p], 6, readers=[r])
        out['silent'] = (len(r.data), r.closed)
        # vanishing mid-HELLO
        r2 = Raw('127.0.0.1:%d' % port, hello=False)
        r2.send(hello_msg()[:20])
        pump_all([p], 3)
        r2.s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        r2.close()
        pump_all([p], 4)
        r.close()
        pump_all([p], 4)
        out['alive'] = p.alive()
        out['end'] = p.q('print(livelink(1), livelink(7))')
        q = out
        p.close()
    check(q['nine'][:8] == [(True, False)] * 8 and q['nine'][8] == (False, True),
          '8 readers get the snapshot, the 9th is let go (%s)' % q['nine'][8:])
    check(q['peers'] == '8\n' and q['after'] == '0\n', 'livelink(1): 8, then 0 when they go (%s, %s)' % (q['peers'].strip(), q['after'].strip()))
    for k in q['bad']:
        ok = q['bad'][k][1] == 0 if k != 'role 7' else True
        check(ok, 'a HELLO with a bad %s: no snapshot (%s)' % (k, 'let go' if q['bad'][k][0] else 'kept, %d messages' % q['bad'][k][1]))
    check(q['pieces'] == [3], 'a HELLO a byte at a time: the snapshot to SNAP_END')
    check(q['silent'] == (0, False), 'a reader with no HELLO: nothing, not let go')
    check(q['alive'] and q['end'].split()[:1] == ['0'], 'a reader gone in the middle of its HELLO: alive, no peers left (%s)' % q['end'].strip())


# ---- backpressure ---------------------------------------------------------------------------

def s_back():
    print('  -- backpressure --', flush=True)
    for which in ('BeeModel',):
        p = Prog()
        port = free_port()
        p.op('link.serve', str(port))
        p.q('for i in 0..1000 { add("cube", "M" + str(i), i % 40, 0, i / 40) }')
        r = Raw('127.0.0.1:%d' % port, rcvbuf=64 * 1024)
        pump_all([p], 20, readers=[r])
        n0 = len([m for m in r.msgs() if m[0] == 12])
        t0 = time.time()
        for k in range(60):                             # it does not read now
            p.q('for i in 0..1000 { set("M" + str(i), "y", %d) }' % (k + 1))
        dt = time.time() - t0
        coal = float(p.q('print(livelink(6))') or -1)
        for _ in range(60):
            p.pump(0.03)
            r.read()
        ms = r.msgs()
        got = len([m for m in ms if m[0] == 12]) - n0
        ys = {}
        for m in ms:
            if m[0] == 12:
                ys[struct.unpack_from('<I', m, 1)[0]] = struct.unpack_from('<f', m, 9)[0]
        latest = set(v for u, v in ys.items() if u > 3)
        check(coal > 0 and 0 < got < 60 * 1000 and latest == {60.0},
              '%s: a reader behind gets %d transforms for 60 x 1000 moves (%.0f held back), each object at its latest place %s, %.1f s'
              % (which, got, coal, sorted(latest)[:3], dt))
        PERF.append(('backpressure: 60 x 1000 moves to a reader behind, s', dt))
        r.close()
        p.close()


# ---- fuzz --------------------------------------------------------------------------

def mk(t, payload=b''):
    return struct.pack('<IB', 1 + len(payload), t) + payload


def mesh_payload(uid, nv=4, polys=((0, 1, 2), (0, 2, 3)), uv=False, rnd=None):
    pos = b''.join(struct.pack('<3f', *(rnd.uniform(-2, 2) for _ in range(3)) if rnd else (i, i * 0.5, 0)) for i in range(nv))
    starts, loops = [0], []
    for p in polys:
        loops += p
        starts.append(len(loops))
    b = struct.pack('<5I', uid, nv, len(polys), len(loops), 1 if uv else 0) + pos
    b += struct.pack('<%dI' % len(starts), *starts) + struct.pack('<%dI' % len(loops), *loops)
    if uv:
        b += struct.pack('<%df' % (2 * len(loops)), *([0.5] * 2 * len(loops)))
    return b


def obj_payload(uid, typ=0, name=b'Obj', mat=-1, flags=0):
    return struct.pack('<IIIIiI', uid, typ, flags, 0xff8800, mat, uid) + name.ljust(32, b'\0')[:32] + struct.pack('<9f', 1, 2, 3, 0, 0.5, 0, 1, 1, 1)


def server_hello():
    return mk(1, b'BEEL' + struct.pack('<HHI', 1, 0, 1234) + b'BeeModel'.ljust(32, b'\0'))


def fuzz_stream(rnd):
    """A server's stream, damaged in one of many ways."""
    good = [server_hello(), mk(2, struct.pack('<3I', 2, 2, 1)),
            mk(30, struct.pack('<I', 0) + b'Mat'.ljust(32, b'\0') + struct.pack('<15f', *[0.5] * 15)),
            mk(20, mesh_payload(7)), mk(10, obj_payload(7)), mk(20, mesh_payload(8, uv=True)), mk(10, obj_payload(8, mat=0)),
            mk(10, obj_payload(9, typ=1, name=b'Lamp')), mk(3)]
    tail = [mk(12, struct.pack('<I9f', 7, *[rnd.uniform(-5, 5) for _ in range(9)])),
            mk(13, struct.pack('<II', 7, rnd.choice([1, 2, 3, 4, 9])) + os.urandom(32)),
            mk(21, struct.pack('<5I', 7, 1, 1, 2, 0) + struct.pack('<6f', 1, 1, 1, 2, 2, 2)),
            mk(11, struct.pack('<I', 8)), mk(4, struct.pack('<Q', 5))]
    msgs = good + tail
    kind = rnd.randrange(14)
    if kind == 0:     # garbage after the HELLO
        msgs = [server_hello(), os.urandom(rnd.randrange(1, 4000))]
    elif kind == 1:   # a message cut short (its length says more)
        k = rnd.randrange(1, len(msgs))
        m = msgs[k]
        msgs[k] = m[:4] + m[4:rnd.randrange(5, len(m) + 1)]
    elif kind == 2:   # a length that lies (shorter than the payload a type needs)
        k = rnd.randrange(1, len(msgs))
        m = msgs[k]
        cut = rnd.randrange(1, len(m) - 4 + 1)
        msgs[k] = struct.pack('<I', cut) + m[4:4 + cut]
    elif kind == 3:   # a zero length
        msgs.insert(rnd.randrange(1, len(msgs)), b'\0\0\0\0')
    elif kind == 4:   # a huge length (more than the input buffer)
        msgs.insert(rnd.randrange(1, len(msgs)), struct.pack('<IB', 0xfffffff0, 20) + os.urandom(100))
    elif kind == 5:   # MESH counts that point outside the message
        msgs.insert(3, mk(20, struct.pack('<5I', 7, rnd.choice([0xffffffff, 1 << 28, 5000]), rnd.choice([0xffffffff, 3, 1 << 30]),
                                          rnd.choice([0xffffffff, 7, 1 << 29]), rnd.randrange(2)) + os.urandom(rnd.randrange(0, 300))))
    elif kind == 6:   # loops past the vertices, starts past the loops, backward starts
        b = bytearray(mesh_payload(7))
        o = 20 + 4 * 12
        which = rnd.randrange(3)
        if which == 0:
            struct.pack_into('<I', b, o + 3 * 4, 99)
        elif which == 1:
            struct.pack_into('<I', b, o + 4, 0xffffff00)
        else:
            struct.pack_into('<3I', b, o, 6, 0, 3)
        msgs.insert(3, mk(20, bytes(b)))
    elif kind == 7:   # a delta out of range, or with more ranges than bytes
        msgs.append(mk(21, struct.pack('<4I', 7, rnd.choice([1, 1000, 0xffffffff]), rnd.choice([0, 3, 0xfffffffe, 1 << 31]), rnd.choice([1, 2, 0x7fffffff]))
                       + os.urandom(rnd.randrange(0, 40))))
    elif kind == 8:   # random types, random payloads
        for _ in range(rnd.randrange(1, 30)):
            msgs.insert(rnd.randrange(1, len(msgs) + 1), mk(rnd.choice([0, 5, 9, 14, 19, 22, 29, 31, 255] + list(NAMES)), os.urandom(rnd.randrange(0, 120))))
    elif kind == 9:   # no HELLO first / a bad one
        msgs[0] = rnd.choice([mk(2, b''), mk(1, b'BEEX' + b'\0' * 40), mk(1, b'BEEL\x02\0' + b'\0' * 38), b'\0\0\0\0'])
    elif kind == 10:  # many objects, a snapshot again, deletions
        for u in range(100, 100 + rnd.randrange(50, 400)):
            msgs.append(mk(20, mesh_payload(u, rnd=rnd)))
            msgs.append(mk(10, obj_payload(u, name=b'O%d' % u)))
        msgs += [mk(2, b'\0' * 12)] + [mk(11, struct.pack('<I', u)) for u in range(100, 140)]
    elif kind == 11:  # a material index far out, names without an end
        msgs.append(mk(30, struct.pack('<I', rnd.choice([255, 256, 1000, 0xffffffff])) + b'X' * 32 + os.urandom(60)))
        msgs.append(mk(10, struct.pack('<IIIIiI', 7, 0, 0xffffffff, 0, 0x7ffffffe, 7) + b'Y' * 32 + os.urandom(36)))
        msgs.append(mk(13, struct.pack('<II', 7, 2) + struct.pack('<i', 70000) + b'\0' * 28))
    elif kind == 12:  # bytes flipped anywhere after the HELLO
        b = bytearray(b''.join(msgs))
        for _ in range(rnd.randrange(1, 12)):
            i = rnd.randrange(len(server_hello()), len(b))
            b[i] = rnd.randrange(256)
        return bytes(b)
    else:             # a valid stream, cut anywhere (the server vanishes mid-message)
        b = b''.join(msgs)
        return b[:rnd.randrange(1, len(b))]
    return b''.join(msgs)


def s_fuzz():
    print('  -- fuzz: damaged streams to a mirror, junk to a server --', flush=True)
    rnd = random.Random(1313)
    p = Prog()
    lis = socket.socket()
    SOCKS.append(lis)
    lis.bind(('127.0.0.1', 0))
    lis.listen(4)
    lis.settimeout(5)
    lport = lis.getsockname()[1]
    rss0 = None
    hangs = 0
    counts = []
    t0 = time.time()
    for k in range(NFUZZ):
        data = fuzz_stream(rnd)
        p.tool('run_operator', {'id': 'link.connect', 'arg': '127.0.0.1:%d' % lport})
        try:
            c, _ = lis.accept()
        except OSError:
            hangs += 1
            continue
        SOCKS.append(c)
        try:
            c.settimeout(2)
            c.recv(64)                 # its HELLO
            for o in range(0, len(data), rnd.choice([7, 100, 4096, 1 << 20])):
                c.sendall(data[o:o + 4096 if len(data) > 1 << 20 else len(data)][: (1 << 20)])
                if rnd.random() < 0.2:
                    p.pump(0.005)
        except OSError:
            pass
        p.pump(0.02)
        if rnd.random() < 0.5:
            c.close()
        r = p.q('print(count(), livelink(4))')
        try:
            counts.append(int(r.split()[0]))
        except (ValueError, IndexError):
            pass
        if not r:
            hangs += 1
            print('       no answer after stream', k)
            break
        c.close()
        p.op('link.disconnect')
        if k == 10:
            rss0 = p.rss_kb()
    rss1 = p.rss_kb()
    check(p.alive() and hangs == 0 and len(set(counts)) > 3,
          '%d damaged streams to the mirror: alive, answering (%.0f s; the scene it made had %d to %d objects)'
          % (NFUZZ, time.time() - t0, min(counts or [0]), max(counts or [0])))
    check(rss0 is not None and rss1 < rss0 + 64 * 1024, 'its memory: %d KiB after 10 streams, %d after %d' % (rss0 or -1, rss1, NFUZZ))
    lis.close()
    # the mirror's scene after the damage is still a scene: it saves and opens
    data = p.save('after.bee')
    check(data is not None and data[:4] == b'BEEM', 'the mirror\'s scene saves after the fuzz')
    # junk and vanishing peers at its server
    port = free_port()
    p.q('for i in 0..50 { add("sphere", "S" + str(i), i, 0, 0) }\nop("link.serve", "%d")' % port)
    p.pump(0.2)
    kept = []
    for k in range(NFUZZ):
        r = Raw('127.0.0.1:%d' % port, hello=False)
        kept.append(r)
        what = rnd.randrange(6)
        if what == 0:
            r.send(os.urandom(rnd.randrange(1, 3000)))
        elif what == 1:
            r.send(hello_msg()[:rnd.randrange(1, 49)])
        elif what == 2:
            r.send(hello_msg() + os.urandom(rnd.randrange(1, 100000)))
        elif what == 3:
            r.send(hello_msg())
            p.pump(0.01)
            r.s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        elif what == 4:
            r.send(hello_msg())
        p.pump(0.01)
        if rnd.random() < 0.7:
            r.close()
        if k % 20 == 0:
            p.q('move("S1", %d, 0, 0)' % k)
    # (silent peers hold their places: 8 at most)
    full = Raw('127.0.0.1:%d' % port)
    pump_all([p], 6, readers=[full])
    for r in kept:
        r.close()
    pump_all([p], 10)
    r = Raw('127.0.0.1:%d' % port)
    pump_all([p], 10, readers=[r])
    check(p.alive() and r.msgs() and r.msgs()[-1][0] == 3, '%d junk / vanishing / flooding peers: alive, a new reader still gets the snapshot' % NFUZZ)
    r.close()
    # a slow reader of a big scene, and one that never reads: the others go on
    p.q('for i in 0..50 { select("S" + str(i))\nop("object.modifier_add", "subsurf") }')
    slow = Raw('127.0.0.1:%d' % port, rcvbuf=4096)
    deaf = Raw('127.0.0.1:%d' % port, rcvbuf=4096)
    fast = Raw('127.0.0.1:%d' % port)
    for k in range(40):
        p.q('for i in 0..50 { set("S" + str(i), "y", %d) }' % k)
        p.pump(0.01)
        fast.read()
        if k % 4 == 0:
            slow.s.recv(2048) if select_ready(slow.s) else None
    pump_all([p], 20, readers=[fast])
    ys = set()
    for m in fast.msgs():
        if m[0] == 12:
            ys.add(struct.unpack_from('<f', m, 9)[0])
    check(p.alive() and 39.0 in ys, 'a slow reader and a deaf one do not hold the others back (the fast one saw y = 39)')
    for x in (slow, deaf, fast):
        x.close()
    pump_all([p], 6)
    check(p.q('print(livelink(1))') == '0\n', 'all gone: livelink(1) 0')
    p.close()


# ---- performance ------------------------------------------------------------------------------

def s_perf():
    print('  -- performance (BIN %s) --' % ('release: LL_REL' if REL != BIN else 'as given'), flush=True)
    p = Prog(binary=REL)
    port = free_port()
    p.op('link.serve', str(port))
    p.q('add("sphere", "Ball", 0, 0, 0)')
    r = Raw('127.0.0.1:%d' % port)
    pump_all([p], 10, readers=[r])
    # a reader in a thread of its own, reading as the bytes come
    import threading
    stop = [False]
    arr = []          # (TICK ns, the TRANSFORM's arrival ns)

    def run():
        buf = b''
        tick = None
        r.s.setblocking(True)
        r.s.settimeout(0.2)
        while not stop[0]:
            try:
                c = r.s.recv(1 << 20)
            except socket.timeout:
                continue
            except OSError:
                return
            if not c:
                return
            now = time.monotonic_ns()
            buf += c
            while len(buf) >= 4:
                ln = struct.unpack_from('<I', buf)[0]
                if len(buf) < 4 + ln:
                    break
                m = buf[4:4 + ln]
                buf = buf[4 + ln:]
                if m[0] == 4:
                    tick = struct.unpack_from('<Q', m, 1)[0]
                elif m[0] == 12 and tick:
                    arr.append((tick, now))
    th = threading.Thread(target=run)
    th.start()
    lat = []
    for i in range(40):
        n = len(arr)
        p.call('tools/call', {'name': 'script_eval', 'arguments': {'code': 'move("Ball", %d, 1, 0)' % i}})
        end = time.time() + 2
        while len(arr) == n and time.time() < end:
            time.sleep(0.0005)
        if len(arr) > n:
            lat.append((arr[n][1] - arr[n][0]) / 1e6)
    stop[0] = True
    th.join()
    r.s.setblocking(False)
    lat.sort()
    q = {'lat': lat[len(lat) // 2] if lat else -1, 'worst': lat[-1] if lat else -1, 'n': len(lat)}
    # a big snapshot: 200 spheres subdivided (the meshes' bytes)
    p.q('for i in 0..200 { add("sphere", "S" + str(i), i, 0, 0)\nselect("S" + str(i))\nop("object.modifier_add", "subsurf") }')
    pump_all([p], 4, readers=[r])
    t0 = time.time()
    r2 = Raw('127.0.0.1:%d' % port)
    done = False
    while time.time() - t0 < 30:
        p.pump(0.002)
        r2.read()
        ms = r2.msgs()
        if ms and ms[-1][0] == 3:
            done = True
            break
    q['snap'] = time.time() - t0
    q['snap_mb'] = len(r2.data) / 1e6
    # a turn's changes: 200 objects moved, all of them at the reader
    t0 = time.time()
    p.q('for i in 0..200 { set("S" + str(i), "z", 7) }')
    n0 = len([m for m in r2.msgs() if m[0] == 12])
    got = 0
    while time.time() - t0 < 10:
        p.pump(0.002)
        r2.read()
        got = len([m for m in r2.msgs() if m[0] == 12]) - n0
        if got >= 200:
            break
    q['moves'] = time.time() - t0
    r.close()
    r2.close()
    p.close()
    PERF.append(('a move to the reader, median ms', q['lat']))
    PERF.append(('a snapshot of 200 subdivided spheres, s (%.1f MB)' % q['snap_mb'], q['snap']))
    PERF.append(('200 objects moved in one turn, all at the reader, s', q['moves']))
    for k, a in PERF:
        print('     %-62s %8.3f' % (k, a))
    check(q['n'] == 40 and 0 <= q['lat'] < 16.7, 'a move reaches the reader within a frame: median %.2f ms, worst %.2f (%d of 40 arrived)' % (q['lat'], q['worst'], q['n']))
    check(done and q['snap'] < 30, 'the big snapshot arrives whole: %.2f s, %.2f MB' % (q['snap'], q['snap_mb']))
    check(got >= 200, '200 objects moved in one turn: all at the reader (%d, %.2f s)' % (got, q['moves']))


# ---- the look ------------------------------------------------------------------------------------

def s_look():
    print('  -- the look: the status bar\'s chip --', flush=True)
    import numpy as np
    shots = {}
    p = Prog()
    pump_all([p], 10)
    shots['before'] = p.image()
    port = free_port()
    p.op('link.serve', str(port))
    pump_all([p], 10)
    shots['serve'] = p.image()
    p.op('link.stop')
    pump_all([p], 10)
    shots['stopped'] = p.image()
    lis = socket.socket()
    lis.bind(('127.0.0.1', 0))
    lis.listen(1)
    SOCKS.append(lis)
    p.op('link.connect', '127.0.0.1:%d' % lis.getsockname()[1])
    pump_all([p], 10)
    shots['mirror'] = p.image()
    p.op('link.disconnect')
    pump_all([p], 10)
    shots['off'] = p.image()
    lis.close()
    p.close()
    out = os.environ.get('LL_SHOTS')
    for k, im in shots.items():
        if out:
            im.save(os.path.join(out, k + '.png'))

    # the chips' rounded background in the status bar: the link's chip adds to it
    sv = np.asarray(shots['serve']).astype(int)
    h, w = sv.shape[:2]
    col = sv[h - 11, w - 14]   # (inside the right-most chip: the link's while serving)

    def chips(k):
        x = np.asarray(shots[k]).astype(int)[h - 22:]
        return int((np.abs(x - col).max(axis=2) <= 2).sum())
    n = {k: chips(k) for k in shots}
    check(n['serve'] > n['before'] + 400, '"Live link: serving": the chip is drawn (%d chip pixels, %d before)' % (n['serve'], n['before']))
    check(n['mirror'] > n['before'] + 400, '"Live link: mirroring": the chip is drawn (%d chip pixels)' % n['mirror'])
    check(abs(n['stopped'] - n['before']) < 50 and abs(n['off'] - n['before']) < 50,
          'the chip goes when the serving and the mirroring stop (%d, %d chip pixels)' % (n['stopped'], n['off']))


# ---- main --------------------------------------------------------------------------------

def main():
    print('live link: %s' % BIN)
    try:
        for _ in range(RUNS):
            for name, f in (('wire', s_wire), ('ops', s_ops), ('mirror', s_mirror), ('limits', s_limits),
                            ('back', s_back), ('fuzz', s_fuzz), ('perf', s_perf), ('look', s_look)):
                if section(name):
                    t0 = time.time()
                    try:
                        f()
                    except Exception as e:
                        import traceback
                        traceback.print_exc()
                        check(False, '%s: %r' % (name, e))
                    print('     (%s: %.0f s)' % (name, time.time() - t0), flush=True)
    finally:
        cleanup()
    print('live link: %d checks failed' % len(FAILS) if FAILS else 'live link: all checks passed')
    print('... fails %d' % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
