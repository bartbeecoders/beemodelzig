#!/usr/bin/env python3
"""The MCP server (mcp.zig, mcpmat.zig, agent.zig): BeeModel in the fake
compositor (tests/wl_fake.py), with its own temp HOME and XDG_RUNTIME_DIR, an MCP
client on its socket. Every reply must be well-formed JSON-RPC 2.0 (the request's
id back, the error codes of the spec), the tools must do what they say (the
scene read back with scene_summary), refuse what they must refuse, make one
undo step per request (undo puts the scene back), save files that read back
and open again as the same scene, and the server must survive garbage.

    python3 tests/mcp.py BIN [runs=1]

BEE_CPU (default 12) pins BeeModel; MCP_ONLY=proto,tools,... runs some
sections; MCP_FUZZ (default 300) sets the transport fuzz's message count;
MCP_REL (a release build) times the big scene.
"""
import base64, io, json, math, os, random, re, shutil, socket, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = int(os.environ.get('BEE_CPU', '12'))
ONLY = [x for x in os.environ.get('MCP_ONLY', '').split(',') if x]
NFUZZ = int(os.environ.get('MCP_FUZZ', '300'))
FAILS = []
SWEEP = {}
T = tempfile.mkdtemp(prefix='bmcp-', dir='/tmp')   # (short: unix socket paths)
os.environ['TMPDIR'] = T
tempfile.tempdir = T

STUBS = os.path.join(T, 'stubs')
os.makedirs(STUBS)
for _tool in ('curl', 'wget', 'claude', 'grok', 'git', 'ssh', 'nc'):
    with open(os.path.join(STUBS, _tool), 'w') as _f:
        _f.write('#!/bin/sh\necho "stub: no network in tests" >&2\nexit 1\n')
    os.chmod(os.path.join(STUBS, _tool), 0o755)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


# ---- the program ------------------------------------------------------------------

class Prog:
    """BeeModel in its fake compositor, with MCP clients on its socket."""

    def __init__(self, perm=None, binary=None, size=(1280, 800)):
        from wl_fake import Fake
        self.home = tempfile.mkdtemp(prefix='h', dir=T)
        # never the network nor real AI tools: stubs first on PATH
        env = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0', 'PATH': STUBS + ':' + os.environ.get('PATH', ''),
               'HOME': self.home, 'XDG_RUNTIME_DIR': self.home, 'XDG_CACHE_HOME': os.path.join(self.home, 'cache')}
        if perm:
            env['BEEMODEL_AGENT_PERMISSION'] = perm
        self.f = Fake(binary or BIN, size=size, env=env)
        self.f.until(lambda: self.f.frames > 0, 10)
        self.pid = self.f.proc.pid
        os.sched_setaffinity(self.pid, {CPU})
        self.pump(0.3)
        self.s = self.connect()
        self.buf = b''

    def pump(self, t=0.05):
        self.f.pump(t)

    def alive(self):
        return self.f.proc.poll() is None

    def frames(self):
        return self.f.frames

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(50):
            try:
                s.connect(os.path.join(self.home, 'beemodel.sock'))
                break
            except OSError:
                self.pump(0.1)
        s.setblocking(False)
        return s

    def send(self, line, s=None):
        try:
            (s or self.s).sendall(line if isinstance(line, bytes) else line.encode())
        except OSError:
            pass

    def reply(self, timeout=5.0, s=None, buf_owner=None):
        """The next reply line (bytes, without the newline), or None."""
        s = s or self.s
        end = time.time() + timeout
        while time.time() < end:
            if b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                return line
            self.pump(0.01)
            try:
                c = s.recv(1 << 22)
                if c == b'':
                    return None
                self.buf += c
            except BlockingIOError:
                pass
            except OSError:
                return None
        return None

    def raw(self, line, timeout=5.0, tag=False):
        """One request, its reply (replies to earlier requests that came too
        late are passed over: a request carries a fresh id inside the test
        and gets the caller's back)."""
        line = line.replace('$HOME', self.home)
        self.seq = getattr(self, 'seq', 0) + 1
        mark = None
        try:
            m = json.loads(line)
            if tag and isinstance(m, dict) and 'id' in m and 'method' in m:
                mark = m['id']
                m['id'] = f'q{self.seq}'
                line = json.dumps(m, separators=(',', ':'), ensure_ascii=False)
        except ValueError:
            pass
        t0 = time.time()
        self.send(line + '\n')
        while True:
            r = self.reply(max(0.1, timeout - (time.time() - t0)))
            if r is None or mark is None:
                break
            want = ('"id":"q%d"' % self.seq).encode()
            if not r.startswith(b'{"jsonrpc":"2.0","id":"q%d",' % self.seq):
                continue   # a late reply to an earlier request (or to junk)
            if want in r[:40]:
                r = r.replace(want, b'"id":' + json.dumps(mark, separators=(',', ':')).encode(), 1)
            break
        self.slow = time.time() - t0
        return r.decode('utf-8', 'replace') if r is not None else None

    def call(self, method, params=None, rid=1):
        m = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params is not None:
            m['params'] = params
        return self.raw(json.dumps(m, separators=(',', ':')), tag=True)

    def tool(self, name, args=None, rid=1):
        r = self.call('tools/call', {'name': name, 'arguments': args or {}}, rid)
        try:
            res = json.loads(r)['result']
            return res['content'][0]['text'], res['isError'], r
        except (TypeError, ValueError, KeyError):
            return None, None, r

    def scene(self):
        t, _, _ = self.tool('scene_summary')
        try:
            return json.loads(norm(t))
        except (TypeError, ValueError):
            return None

    def image(self):
        from PIL import Image
        s = self.f.surfaces[self.f.main().surface]
        last = s.get('last')
        bf = self.f.buffers[last]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            return self.f.close()
        except Exception:
            return ''


def norm(r, home=None):
    """A reply with what changes from run to run made alike."""
    if r is None:
        return None
    if home:
        r = r.replace(home, '$HOME')
    r = re.sub(r'"data":"[A-Za-z0-9+/=]+"', '"data":"<png>"', r)
    r = re.sub(r'\d+ KiB of snapshots', 'N KiB of snapshots', r)
    return r


def finite(v):
    """Every number in a JSON value finite."""
    if isinstance(v, float):
        return math.isfinite(v)
    if isinstance(v, dict):
        return all(finite(x) for x in v.values())
    if isinstance(v, list):
        return all(finite(x) for x in v)
    return True


def wellformed(r, rid=..., code=None):
    """A JSON-RPC 2.0 reply: strict JSON, "jsonrpc":"2.0", the id (when given),
    a result or an error (with the code, when given); a tools/call result has
    its content and isError. '' when fine, else what is wrong."""
    if r is None:
        return 'no reply'
    try:
        m = json.loads(r, strict=True)
    except ValueError as e:
        return f'not JSON ({e})'
    if not isinstance(m, dict) or m.get('jsonrpc') != '2.0':
        return 'not JSON-RPC 2.0'
    if rid is not ... and m.get('id', 'missing') != rid:
        return f'the id {m.get("id", "missing")!r}, not {rid!r}'
    if ('result' in m) == ('error' in m):
        return 'not one of result and error'
    if code is not None:
        if m.get('error', {}).get('code') != code:
            return f'not the error {code}'
    elif 'error' in m:
        e = m['error']
        if not isinstance(e.get('code'), int) or not isinstance(e.get('message'), str):
            return 'an error without its code and message'
    if not finite(m):
        return 'a number not finite'
    return ''


class One:
    """The checks on one program: replies well formed, tools as asked."""

    def __init__(self, perm=None):
        self.p = Prog(perm)

    def ask(self, line, name=None, rid=..., code=None, show=True):
        r = self.p.raw(line)
        bad = wellformed(r, rid, code)
        if name:
            check(not bad, name + (f' ({bad})' if bad else ''))
            if bad and show:
                print('     reply:', (r or 'None')[:600])
        return r

    def tool(self, name, args=None, label=None, err=None, has=None, show=True):
        """err: True / False, isError must be that; has: text the answer holds."""
        line = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}, separators=(',', ':'))
        r = self.p.raw(line, tag=True)
        bad = wellformed(r, 1)
        t = e = None
        if not bad:
            try:
                res = json.loads(r)['result']
                t, e = res['content'][0]['text'], res['isError']
                if not isinstance(t, str) or not isinstance(e, bool):
                    bad = 'no text or isError'
            except (KeyError, IndexError, TypeError):
                bad = 'no result content'
        if not bad and err is not None and e != err:
            bad = 'an error' if e else 'no error'
        if not bad and has is not None and has.replace('$HOME', self.p.home) not in t:
            bad = f'{has!r} not in the answer'
        if label:
            check(not bad, label + (f' ({bad})' if bad else ''))
            if bad and show:
                print('     reply:', (r or 'None')[:600])
        return t, e, r

    def scene(self):
        return self.p.scene()

    def scene_ok(self, label):
        """scene_summary: well formed, names unique, finite numbers in their
        shortest form (no trailing zeros)."""
        t, _, _ = self.p.tool('scene_summary')
        try:
            sc = json.loads(norm(t))
        except (TypeError, ValueError):
            sc = None
        if t and re.search(r'[:\[,]-?\d+\.\d*0[,\]}]', t):
            check(False, label + ': a number with trailing zeros')
        ok = sc is not None and isinstance(sc.get('objects'), list) and finite(sc)
        names = [o['name'] for o in sc['objects']] if ok else []
        ok = ok and len(names) == len(set(names)) and all(0 < len(n.encode()) <= 31 for n in names)
        check(ok, label + ('' if ok else f' ({names})'))
        return sc

    def same_scene(self, want, label):
        sc = self.p.scene()
        check(sc is not None and sc == want, label)
        if sc != want and sc and want:
            a = [o['name'] for o in want['objects']]
            b = [o['name'] for o in sc['objects']]
            print('     objects', a, '/', b)
            for x, y in zip(want['objects'], sc['objects']):
                if x != y:
                    print('     was:', json.dumps(x)[:300])
                    print('     now:', json.dumps(y)[:300])
                    break
        return sc

    def close(self):
        return self.p.close()


def obj(sc, name):
    for o in (sc or {}).get('objects', []):
        if o['name'] == name:
            return o
    return None


def near(a, b, eps=1e-3):
    return a is not None and b is not None and len(a) == len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


def bare(sc):
    """A scene without the selection (undo puts the selection of the request's
    start back, not the one before it)."""
    return sc and {k: v for k, v in sc.items() if k != 'objects'} | {'objects': [{k: v for k, v in o.items() if k not in ('selected', 'active')} for o in sc['objects']]}


def section(name):
    return not ONLY or name in ONLY


# ---- the protocol ------------------------------------------------------------------

def s_proto():
    print('-- the protocol: JSON-RPC framing, errors, ids, initialize, lists')
    P = One()
    try:
        # (label, line, the id back (... the request's), the error code or None)
        cases = [
            ('initialize, the client\'s version echoed', '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}', ..., None),
            ('initialize without params', '{"jsonrpc":"2.0","id":2,"method":"initialize"}', ..., None),
            ('initialize with an empty version', '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":""}}', ..., None),
            ('initialize with a number for the version', '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":5}}', ..., None),
            ('initialize with a 100-byte version (63 kept)', '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"' + 'v' * 100 + '"}}', ..., None),
            ('ping', '{"jsonrpc":"2.0","id":6,"method":"ping"}', ..., None),
            ('an unknown method: -32601', '{"jsonrpc":"2.0","id":7,"method":"no/such"}', ..., -32601),
            ('broken JSON: -32700, id null', '{"jsonrpc":"2.0","id":8,"method":"ping"', None, -32700),
            ('trailing garbage: -32700', '{"jsonrpc":"2.0","id":9,"method":"ping"} x', None, -32700),
            ('not an object: -32600, id null', '[1,2,3]', None, -32600),
            ('a string: -32600', '"ping"', None, -32600),
            ('no method: -32600 with the id', '{"jsonrpc":"2.0","id":10}', ..., -32600),
            ('a string id echoed as it came', '{"jsonrpc":"2.0","id":"a\\"b","method":"ping"}', ..., None),
            ('an object id echoed', '{"jsonrpc":"2.0","id":{"x":[1,2]},"method":"ping"}', ..., None),
            ('a float id echoed', '{"jsonrpc":"2.0","id":-1.5e3,"method":"ping"}', ..., None),
            ('a null id echoed', '{"jsonrpc":"2.0","id":null,"method":"ping"}', ..., None),
            ('the method escaped is ping', '{"jsonrpc":"2.0","id":11,"method":"p\\u0069ng"}', ..., None),
            ('the method not a string', '{"jsonrpc":"2.0","id":12,"method":5}', ..., -32600),
            ('keys in any order, whitespace', ' { "method" : "ping" , "id" : 13 , "jsonrpc" : "2.0" } ', ..., None),
            ('deep nesting (64): fine', '{"jsonrpc":"2.0","id":14,"method":"ping","params":' + '[' * 62 + ']' * 62 + '}', ..., None),
            ('deeper (65): -32700', '{"jsonrpc":"2.0","id":15,"method":"ping","params":' + '[' * 64 + ']' * 64 + '}', None, -32700),
            ('a control character in a string: -32700', '{"jsonrpc":"2.0","id":16,"method":"pi\x01ng"}', None, -32700),
            ('resources/list', '{"jsonrpc":"2.0","id":17,"method":"resources/list"}', ..., None),
            ('resources/read bee://scene', '{"jsonrpc":"2.0","id":18,"method":"resources/read","params":{"uri":"bee://scene"}}', ..., None),
            ('resources/read without a uri: the scene', '{"jsonrpc":"2.0","id":19,"method":"resources/read"}', ..., None),
            ('resources/read bee://graphs (no trees)', '{"jsonrpc":"2.0","id":20,"method":"resources/read","params":{"uri":"bee://graphs"}}', ..., None),
            ('tools/call without params: unknown tool ""', '{"jsonrpc":"2.0","id":21,"method":"tools/call"}', ..., None),
            ('tools/call of an unknown tool', '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"nope","arguments":{}}}', ..., None),
            ('a tool name with escapes: decoded, written back escaped', '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"a\\u0007b\\u00e9\\u20ac\\n\\"q\\"\\\\"}}', ..., None),
            ('a tool name of 120 bytes (95 kept)', '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"' + 'x' * 120 + '"}}', ..., None),
        ]
        R = {}
        for name, line, rid, code in cases:
            if rid is ...:
                rid = json.loads(line)['id']
            R[name] = P.ask(line, name + ': well formed', rid=rid, code=code)
        res = lambda n: (json.loads(R[n] or 'null') or {}).get('result') or {}
        check(res(cases[0][0]).get('protocolVersion') == '2025-03-26', 'initialize: the client\'s version back')
        check(res(cases[4][0]).get('protocolVersion') == 'v' * 63, 'initialize: a long version cut to 63 bytes')
        check('tools' in res(cases[1][0]).get('capabilities', {}), 'initialize: the tools capability')
        check(res('ping') == {} and res('the method escaped is ping') == {}, 'ping: an empty result, the escaped name too')
        txt = lambda n: (res(n).get('content') or [{}])[0].get('text', '')
        check(res('tools/call of an unknown tool').get('isError') is True and 'nope' in txt('tools/call of an unknown tool'), 'an unknown tool: an error naming it')
        check('a\x07bé€\n"q"\\' in txt('a tool name with escapes: decoded, written back escaped'), 'the escaped tool name decoded in the answer')
        t = txt('a tool name of 120 bytes (95 kept)')
        check('x' * 95 in t and 'x' * 96 not in t, 'a 120-byte tool name: 95 kept')
        sc = res('resources/read bee://scene').get('contents') or [{}]
        try:
            ok = isinstance(json.loads(sc[0].get('text', '')).get('objects'), list)
        except (ValueError, AttributeError):
            ok = False
        check(ok, 'bee://scene: the scene as JSON')
        # notifications and responses get no answer: a ping after them is the next reply
        for name, line in [('a notification: no answer', '{"jsonrpc":"2.0","method":"notifications/initialized"}'),
                           ('a response to us: no answer', '{"jsonrpc":"2.0","id":5,"result":{}}'),
                           ('an error response: no answer', '{"jsonrpc":"2.0","id":5,"error":{"code":1}}'),
                           ('a notification of an unknown method: no answer', '{"jsonrpc":"2.0","method":"x/y"}'),
                           ('an empty line: a parse error', '')]:
            P.p.send(line + '\n{"jsonrpc":"2.0","id":99,"method":"ping"}\n')
            rp = P.p.reply()
            if line == '':
                r2 = P.p.reply()
                check(b'-32700' in (rp or b'') and b'"id":99' in (r2 or b''), name)
            else:
                check(b'"id":99' in (rp or b''), name)
        # tools/list: the curated tools and every agent-safe operator not hidden, in aisafe.zig's order
        rp = json.loads(P.p.call('tools/list'))
        tp = rp['result']['tools']
        check(all(isinstance(t.get('name'), str) and isinstance(t.get('inputSchema'), dict) for t in tp) and len({t['name'] for t in tp}) == len(tp),
              f'tools/list: {len(tp)} tools, each with a name and a schema, no name twice')
        src = open(os.path.join(ROOT, 'src', 'catalog.zig')).read()
        hidden = set(re.findall(r'\.id = "([^"]+)"[^\n]*\.hidden = true', src))
        ids = re.findall(r'"([^"]+)"', open(os.path.join(ROOT, 'src', 'aisafe.zig')).read().split('ids =')[1].split('};')[0])
        want = ['op_' + i.replace('.', '_') for i in ids if i not in hidden]
        got = [t['name'] for t in tp if t['name'].startswith('op_')]
        check(got == want, f'the agent-safe operators: {len(got)}, those of aisafe.zig not hidden ({len(want)}), in its order')
        check(P.p.call('tools/list') == P.p.call('tools/list'), 'tools/list the same twice')
        pp = P.p.call('prompts/list')
        check(not wellformed(pp, 1) and '"procedural"' in pp, 'prompts/list: procedural among them')
        check(P.p.alive(), 'still running')
    finally:
        P.close()


# ---- the curated tools ----------------------------------------------------------------

def s_tools():
    print('-- the curated tools')
    P = One()
    try:
        s0 = P.scene_ok('scene_summary of the default scene')
        n = len(s0['objects']) if s0 else 0
        for ty in ['cube', 'sphere', 'cylinder', 'cone', 'torus', 'plane', 'grid', 'light', 'camera']:
            P.tool('create_primitive', {'type': ty}, f'create_primitive {ty}', err=False)
        sc = P.scene_ok('the scene after the creations')
        check(sc and len(sc['objects']) == n + 9, f'nine objects more ({len(sc["objects"]) if sc else 0})')
        plain_cone = [o for o in sc['objects'] if o['name'] == 'Cone']
        base = [o for o in sc['objects'] if o['name'] == 'Cube.001' or o['name'] == 'Cube'][-1]
        P.tool('create_primitive', {'type': 'cone', 'name': 'Spike', 'location': [1, 2, 3], 'rotation_deg': [10, 20, 30], 'scale': [1, 2, 1]}, 'create_primitive with a name and a transform', err=False)
        sp = obj(P.scene(), 'Spike')
        check(sp and near(sp['location'], [1, 2, 3]) and near(sp['rotation_deg'], [10, 20, 30]) and near(sp['scale'], [1, 2, 1]), f'Spike where it was asked ({sp and (sp["location"], sp["rotation_deg"], sp["scale"])})')
        check(sp and plain_cone and near(sp.get('size'), [a * b for a, b in zip(plain_cone[0].get('size', [0, 0, 0]), [1, 2, 1])]), 'its size the cone\'s, scaled')
        P.tool('create_primitive', {'type': 'cube', 'name': 'Spike'}, 'a taken name gets .001', err=False)
        check(obj(P.scene(), 'Spike.001') is not None, 'Spike.001 there')
        P.tool('create_primitive', {'type': 'cube', 'name': 'N' * 40}, 'a long name: cut', err=False)
        P.tool('create_primitive', {'type': 'cube', 'name': 'L2', 'location': [1, 2]}, 'two numbers for a location: ignored', err=False)
        P.tool('create_primitive', {'type': 'cube', 'name': 'L4', 'location': [1, 2, 3, 4]}, 'four numbers: the first three', err=False)
        P.tool('create_primitive', {'type': 'cube', 'name': 'L0', 'location': ['a', True, None]}, 'not numbers: zeros', err=False)
        sc = P.scene()
        check(obj(sc, 'L2') and obj(sc, 'L2')['location'] == base['location'], f'two numbers ignored: where a plain cube goes ({obj(sc, "L2") and obj(sc, "L2")["location"]}, {base["location"]})')
        check(obj(sc, 'L4') and near(obj(sc, 'L4')['location'], [1, 2, 3]), 'four numbers: at 1 2 3')
        check(obj(sc, 'L0') and near(obj(sc, 'L0')['location'], [0, 0, 0]), 'not numbers: at 0 0 0')
        before = P.scene()
        P.tool('create_primitive', {'type': 'dodecahedron'}, 'an unknown type', err=True)
        P.tool('create_primitive', {}, 'no type: missing argument', err=True)
        P.tool('create_primitive', {'type': ''}, 'an empty type: missing argument', err=True)
        P.tool('create_primitive', {'type': 5}, 'a number for the type: missing argument', err=True)
        P.same_scene(before, 'refused creations change nothing')
        P.scene_ok('the scene after the creations: names unique, at most 31 bytes')
        P.tool('set_transform', {'name': 'Spike', 'location': [0, 3, 0], 'scale': [0.5, 0.5, 0.5], 'rotation_deg': [0, 45, 0]}, 'set_transform', err=False)
        sp = obj(P.scene(), 'Spike')
        check(sp and near(sp['location'], [0, 3, 0]) and near(sp['scale'], [0.5] * 3) and near(sp['rotation_deg'], [0, 45, 0]), 'set_transform: there')
        P.tool('set_transform', {'name': 'Spike', 'new_name': 'Cube'}, 'set_transform renames (unique)', err=False)
        sc = P.scene_ok('the names still unique')
        check(sc and obj(sc, 'Spike') is None and sum(o['name'].startswith('Cube') for o in sc['objects']) == sum(o['name'].startswith('Cube') for o in before['objects']) + 1, 'Spike renamed to a free name')
        P.tool('set_transform', {'name': 'Nope'}, 'set_transform of no such object', err=True)
        P.tool('set_transform', {}, 'set_transform without a name', err=True)
        P.tool('set_transform', {'name': 'cube'}, 'names are exact (case)', err=True)
        sel = lambda: sorted(o['name'] for o in P.scene()['objects'] if o['selected'])
        act = lambda: [o['name'] for o in P.scene()['objects'] if o['active']]
        P.tool('select', {'names': ['Cube', 'Light']}, 'select two (the last active)', err=False)
        check(sel() == ['Cube', 'Light'] and act() == ['Light'], f'Cube and Light selected, Light active ({sel()}, {act()})')
        P.tool('select', {'names': ['Camera'], 'extend': True}, 'select with extend', err=False)
        check(sel() == ['Camera', 'Cube', 'Light'], f'extend kept the selection ({sel()})')
        P.tool('select', {'names': ['Nope', 7, 'Sphere']}, 'select with unknown and bad names')
        check('Sphere' in sel(), 'the known one selected')
        P.tool('select', {}, 'select without names: none selected')
        check(sel() == [], 'none selected')
        before = P.scene()
        P.tool('delete', {'names': ['Sphere', 'Torus', 'Nope']}, 'delete')
        after = P.scene()
        check(after and obj(after, 'Sphere') is None and obj(after, 'Torus') is None and len(after['objects']) == len(before['objects']) - 2, 'Sphere and Torus gone')
        P.tool('undo', {}, 'undo', err=False)
        check(bare(P.scene()) == bare(before), 'undo brings them back')
        P.tool('redo', {}, 'redo', err=False)
        check(bare(P.scene()) == bare(after), 'redo deletes them again')
        P.tool('run_operator', {'id': 'view.toggle_grid', 'arg': ''}, 'run_operator view.toggle_grid', err=False)
        P.tool('run_operator', {'id': 'file.exit'}, 'run_operator file.exit: not agent-safe', err=True)
        P.tool('run_operator', {'id': 'no.such'}, 'run_operator of no such operator', err=True)
        P.tool('run_operator', {}, 'run_operator without an id', err=True)
        P.tool('run_operator', {'id': 'file.save', 'arg': '$HOME/x.bee'}, 'run_operator file.save: needs files', err=True)
        check(not os.path.exists(os.path.join(P.p.home, 'x.bee')), 'nothing written without the files permission')
        P.tool('op_view_toggle_grid', {'arg': ''}, 'op_view_toggle_grid', err=False)
        P.tool('op_file_save', {'arg': '$HOME/y.bee'}, 'op_file_save: needs files', err=True)
        P.tool('op_file_exit', {}, 'op_file_exit: not a tool', err=True)
        P.tool('op_agent_permission_files', {}, 'agents cannot raise their own permission', err=True)
        P.tool('op_agent_revert', {}, 'nor revert through a tool', err=True)
        check(P.p.alive(), 'still running after op_file_exit')
        P.tool('script_eval', {}, 'script_eval without code: missing argument', err=True)
        # BeeScript (bscript.zig): what it prints, its errors, one undo step, an agent's limits
        P.tool('script_eval', {'code': 'print(1 + 2)'}, 'script_eval: what it prints', err=False, has='3')
        P.tool('script_eval', {'code': 'x = 2m\nx * 3'}, 'script_eval: the last value', err=False, has='6')
        before = P.scene()
        P.tool('script_eval', {'code': 'for i in 0..5 {\n  add("cube", "S" + i, i * 2, 0, 4)\n}'}, 'script_eval: a loop of adds', err=False)
        sc = P.scene()
        check(all(obj(sc, f'S{i}') and near(obj(sc, f'S{i}')['location'], [i * 2, 0, 4]) for i in range(5)), 'five cubes S0..S4 where the script put them')
        P.tool('undo', {}, 'one undo step for the whole script', err=False)
        P.same_scene(before, 'the five cubes gone at once')
        P.tool('script_eval', {'code': 'print(nope(1))'}, 'script_eval: an error', err=True)
        P.tool('script_eval', {'code': 'op("file.exit")'}, 'script_eval: an operator not agent-safe', err=True)
        P.tool('script_eval', {'code': 'op("file.save", "$HOME/s.bee")'}, 'script_eval: a file operator without the files permission', err=True)
        check(not os.path.exists(os.path.join(P.p.home, 's.bee')), 'and no file')
        P.tool('script_eval', {'code': 'for i in 0..3 {\n  add("sphere", "Q" + i)\n}\nprint(nope)'}, 'script_eval: fails part way', err=True)
        P.scene_ok('the scene after the failed script')
        P.tool('undo', {}, 'undo after the failed script')
        P.same_scene(before, 'the scene as before the failed script')
        P.p.tool('op_area_maximize', {'arg': ''})
        P.p.pump(0.3)
        from PIL import Image, ImageChops
        for area in ['viewport', 'window', 'nope']:
            _, _, rp = P.tool('viewport_capture', {'area': area}, f'viewport_capture {area}: well formed')
            ok = False
            try:
                cp = json.loads(rp)['result']['content']
                ip = Image.open(io.BytesIO(base64.b64decode(cp[1]['data']))).convert('RGB')
                ok = cp[0]['type'] == 'text' and cp[1]['mimeType'] == 'image/png' and len(cp) == 2 and ip.size[0] > 50 and ip.size[1] > 50
                ok = ok and len(ip.resize((64, 40)).getcolors(4096) or []) > 4
                print(f'     {area}: {cp[0]["text"]!r}, {ip.size}')
                if os.environ.get('MCP_SHOTS'):
                    ip.save(os.path.join(os.environ['MCP_SHOTS'], f'cap_{area}.png'))
                if area == 'window':
                    P.p.pump(0.5)
                    fr = P.p.image()
                    # (but the status bar, which ticks on: its last 22 rows)
                    bb = ImageChops.difference(ip.crop((0, 0, 1280, 778)), fr.crop((0, 0, 1280, 778))).getbbox()
                    check(bb is None, f'viewport_capture area=window is the frame shown (apart in {bb})')
            except Exception as ex:
                print('     ', ex)
            check(ok, f'viewport_capture {area}: a text and one PNG of a picture')
        P.p.tool('op_area_maximize', {'arg': ''})
        t, e, _ = P.p.tool('ui_tree')
        try:
            w = json.loads(t)['widgets']
            ok = len(w) > 20 and all(set(x) >= {'name', 'sub', 'kind', 'x', 'y', 'w', 'h', 'label', 'value'} for x in w)
        except (TypeError, ValueError, KeyError):
            ok = False
        check(ok, 'ui_tree: the widgets of the last frame')
        P.scene_ok('the scene at the end')
    finally:
        P.close()


# ---- the material tools ------------------------------------------------------------------

GRAPH = {'nodes': [
    {'type': 'noise', 'values': [5, 4, 0.6], 'inputs': [[0.1, 0.2, 0.3]], 'pos': [-300, 40]},
    {'type': 'mix', 'values': [0.25], 'inputs': [{'link': 1}, [1, 0, 0], {'link': 3, 'output': 0}], 'pos': [-100, 0]},
    {'type': 'constant', 'values': [0.5], 'pos': [-400, 200]},
    {'type': 'scalarparam', 'values': [0.3], 'name': 'Wetness', 'pos': [-500, 300]},
    {'type': 'math', 'values': [2], 'inputs': [{'link': 4}, 0.5], 'pos': [-200, 300]},
], 'sockets': {'base': 2, 'roughness': {'node': 5, 'output': 0}, 'metallic': {'node': 3}, 'nope': 1}}


def s_mat():
    print('-- the material tools')
    P = One()
    try:
        t, _, _ = P.tool('material_node_types', {}, 'material_node_types: the catalogue', err=False)
        try:
            cat = json.loads(t)
            ok = len(cat['material_nodes']) > 5 and all(x.get('type') and isinstance(x.get('outputs'), list) for x in cat['material_nodes'])
            ok = ok and all(isinstance(v.get('kind'), str) and v['kind'] for x in cat['material_nodes'] for v in x.get('values', []) + x.get('inputs', []))
        except (TypeError, ValueError):
            ok = False
        check(ok, 'the catalogue is JSON')
        P.tool('material_graph', {}, 'material_graph without a name', err=True)
        P.tool('material_graph', {'name': 'Nope'}, 'material_graph of no such material', err=True)
        P.tool('material_graph_set', {'name': 'Wet', 'graph': GRAPH}, 'material_graph_set makes a material and its graph', err=False)
        g0, _, _ = P.tool('material_graph', {'name': 'Wet'}, 'material_graph reads it back', err=False)
        try:
            gj = json.loads(g0)
            # (sorted so that links point back: the order may change)
            ok = sorted(x['type'] for x in gj['nodes']) == sorted(x['type'] for x in GRAPH['nodes'])
            ok = ok and [x.get('name') for x in gj['nodes'] if x['type'] == 'scalarparam'] == ['Wetness']
            ok = ok and sorted(x.get('pos') for x in gj['nodes']) == sorted(x['pos'] for x in GRAPH['nodes'])
            ok = ok and set(gj.get('sockets', {})) == {'base', 'roughness', 'metallic'}
            ok = ok and all(isinstance(v, int) and 1 <= v <= 5 for v in gj['sockets'].values())
            ok = ok and all(i['link'] < k + 1 for k, x in enumerate(gj['nodes']) for i in x.get('inputs', []) if isinstance(i, dict))
        except (TypeError, ValueError, KeyError, IndexError):
            ok = False
        check(ok, 'the graph read back: its nodes, places, the parameter\'s name, the sockets (an unknown one dropped)')
        loop = {'nodes': [{'type': 'mix', 'inputs': [{'link': 2}]}, {'type': 'mix', 'inputs': [{'link': 1}]}]}
        P.tool('material_graph_set', {'name': 'Wet', 'graph': loop}, 'a loop is refused', err=True)
        P.tool('material_graph', {'name': 'Wet'}, 'and the graph is as it was', has=g0)
        P.tool('material_graph_set', {'name': 'Wet', 'graph': {'nodes': [{'type': 'warp'}]}}, 'an unknown node type', err=True)
        P.tool('material_graph', {'name': 'Wet'}, 'the graph as it was again', has=g0)
        P.tool('material_graph_set', {'name': 'Wet', 'graph': {'nodes': [{'type': 'constant'}] * 49}}, 'more than 48 nodes', err=True)
        P.tool('material_graph_set', {'name': 'Wet', 'graph': [1]}, 'a graph that is not an object', err=True)
        P.tool('material_graph_set', {'name': 'Wet', 'graph': {'nodes': 5}}, 'nodes that are not a list', err=True)
        P.tool('material_graph_set', {'name': 'Wet'}, 'no graph', err=True)
        P.tool('material_graph_set', {'graph': GRAPH}, 'no name', err=True)
        P.tool('material_graph', {'name': 'Wet'}, 'the graph as it was after the refusals', has=g0)
        P.tool('material_graph_set', {'name': 'Empty', 'graph': {'nodes': []}}, 'an empty graph', err=False)
        P.tool('material_graph_set', {'name': 'Tex', 'graph': {'nodes': [{'type': 'image', 'values': [0]}], 'sockets': {'base': 1}}}, 'an image node behind base (no image)')
        P.tool('material_graph_set', {'name': 'Back', 'graph': {'nodes': [{'type': 'mix', 'inputs': [{'link': 2, 'output': 9}]}, {'type': 'noise'}], 'sockets': {'base': {'node': 1, 'output': 3}}}}, 'a link forward: sorted; outputs masked', err=False)
        sc = P.scene_ok('scene_summary with the materials and graphs')
        mats = [m.get('name') if isinstance(m, dict) else m for m in (sc or {}).get('materials', [])]
        check({'Wet', 'Empty', 'Back'} <= set(mats), f'the materials listed ({mats})')
        t, _, _ = P.p.tool('undo')
        check(t == 'ok\n  undo: Agent: material_graph_set', f'undo takes the last material_graph_set back ({t!r})')
        t, e, _ = P.p.tool('material_graph', {'name': 'Back'})
        check(e and t == 'no material named Back', 'undone: no such material')
        P.p.tool('redo')
        P.tool('material_graph', {'name': 'Back'}, 'redo: it is back', err=False)
        # random graphs: valid and invalid
        rnd = random.Random(7)
        types = ['image', 'noise', 'checker', 'mix', 'math', 'constant', 'color', 'scalarparam', 'vectorparam', 'bump', 'warp']
        bad = 0
        for k in range(30 * RUNS):
            nodes = []
            for _ in range(rnd.randint(0, 7)):
                nd = {'type': rnd.choice(types)}
                if rnd.random() < 0.7:
                    nd['values'] = [rnd.choice([rnd.uniform(-5, 5), 'x', None]) for _ in range(rnd.randint(0, 6))]
                if rnd.random() < 0.7:
                    nd['inputs'] = [rnd.choice([[rnd.uniform(-2, 2)] * rnd.choice([1, 3]), rnd.uniform(0, 1), {'link': rnd.randint(-1, 8), 'output': rnd.randint(0, 9)}, {'link': 'a'}]) for _ in range(rnd.randint(0, 4))]
                if rnd.random() < 0.5:
                    nd['pos'] = [rnd.randint(-40000, 40000), rnd.randint(-900, 900)]
                if rnd.random() < 0.3:
                    nd['name'] = rnd.choice(['P', 'x' * 40, ''])
                nodes.append(nd)
            g = {'nodes': nodes}
            if rnd.random() < 0.6:
                g['sockets'] = {rnd.choice(['base', 'metallic', 'roughness', 'normal', 'mask', 'zz']): rnd.choice([rnd.randint(0, 8), {'node': rnd.randint(0, 8), 'output': rnd.randint(0, 9)}]) for _ in range(3)}
            nm = rnd.choice(['R1', 'R2'])
            prev, _, _ = P.p.tool('material_graph', {'name': nm})
            t, e, r = P.tool('material_graph_set', {'name': nm, 'graph': g})
            now, e2, r2 = P.p.tool('material_graph', {'name': nm})
            fine = not wellformed(r, 1) and not wellformed(r2, 1) and isinstance(e, bool)
            # refused: the graph as it was; taken: it reads back as JSON
            nodes_of = lambda t: json.loads(t).get('nodes', []) if t and t.startswith('{') else []
            try:
                if fine and e:
                    fine = nodes_of(now) == nodes_of(prev)
                elif fine:
                    fine = len(nodes_of(now)) == len(nodes)
            except ValueError:
                fine = False
            if not fine and bad < 3:
                print('     graph:', json.dumps(g)[:300])
                print('     reply:', (r or '')[:300], '/', (r2 or '')[:200])
            bad += not fine
        check(bad == 0 and P.p.alive(), f'{30 * RUNS} random graphs: well formed answers; refused ones leave the graph, taken ones read back ({bad} not)')
        P.scene_ok('and the scene after them')
        t, e, _ = P.p.tool('material_graph_set', {'name': 'S', 'graph': {'nodes': [{'type': 'noise'}, {'type': None}]}})
        check(e and t == 'unknown node type: ', 'a type that is not a string: unknown')
        t, e, _ = P.p.tool('material_graph_set', {'name': 'S', 'graph': {'nodes': [{'type': 'mix', 'inputs': [[0.25, 0.5]]}]}})
        check(not e and '"inputs":[[0.25,0.5,0]' in (t or ''), 'an input of two numbers: the third 0')
    finally:
        P.close()


# ---- files: a scene built by tools, saved, read back, opened -----------------------------

BUILD = [
    ('create_primitive', {'type': 'cube', 'name': 'Base', 'location': [0, 0.5, 0], 'scale': [3, 0.5, 2]}),
    ('create_primitive', {'type': 'sphere', 'name': 'Ball', 'location': [0, 2, 0], 'rotation_deg': [0, 33.3, 0]}),
    ('op_object_modifier_add', {'arg': 'subsurf'}),
    ('op_material_new', {'arg': 'Gold'}),
    ('op_material_set', {'arg': 'Gold metallic 1'}),
    ('op_material_assign', {'arg': 'Gold'}),
    ('material_graph_set', {'name': 'Gold', 'graph': GRAPH}),
    ('create_primitive', {'type': 'torus', 'name': 'Ring', 'location': [2, 1, -1], 'scale': [0.5, 0.5, 0.5]}),
    ('op_text_add', {'arg': '"Hi" 0.5 0.1'}),
    ('set_transform', {'name': 'Text', 'location': [-2, 1, 0], 'new_name': 'Label'}),
    ('op_world_strength', {'arg': '0.75'}),
    ('select', {'names': ['Ball', 'Ring']}),
    ('op_object_parent_set', {'arg': ''}),
    ('delete', {'names': ['Cube']}),
    ('create_primitive', {'type': 'camera', 'name': 'Cam2', 'location': [5, 5, 5], 'rotation_deg': [-30, 45, 0]}),
    ('create_primitive', {'type': 'light', 'name': 'Sun', 'location': [0, 9, 0]}),
]


def s_files():
    print('-- files: a scene built by tools, saved, read back and opened: the same scene')
    import beefile
    P = One(perm='files')
    try:
        for name, args in BUILD:
            P.tool(name, args, f'{name} {json.dumps(args)[:60]}', err=False)
        built = P.scene_ok('the scene built')
        P.tool('run_operator', {'id': 'file.save', 'arg': '$HOME/s.bee'}, 'file.save with the files permission', err=False)
        P.p.pump(0.5)
        path = os.path.join(P.p.home, 's.bee')
        bp = open(path, 'rb').read() if os.path.exists(path) else b''
        try:
            ch = dict(beefile.chunks(bp))
            objs = beefile.objects(bp)
            meshes = beefile.meshes(bp)
        except Exception as ex:
            print('     ', ex)
            ch, objs, meshes = {}, [], []
        check(len(ch) > 5 and all(t in ch for t in (b'OBJS', b'MESH', b'MATS', b'MGRF', b'PRNT')), f'the file reads back: {b" ".join(ch).decode()}')
        check(built and sorted(o['name'] for o in objs) == sorted(o['name'] for o in built['objects']), 'its objects are the scene\'s, by name')
        bo = {o['name']: o for o in objs}
        check(built and all(near(bo[o['name']]['scl'], o['scale']) for o in built['objects'] if o['name'] in bo), 'and their scales')
        check(all(o['mesh'] < len(meshes) for o in objs if o['type'] == 0), 'each mesh object\'s mesh in the file')
        # open it again: the same scene; saved again: the same chunks
        P.tool('op_file_new', {'arg': ''}, 'file.new', err=False)
        P.scene_ok('the default scene again')
        P.tool('op_file_open', {'arg': '$HOME/s.bee'}, 'file.open of the saved file', err=False)
        P.p.pump(0.5)
        P.same_scene(built, 'the same scene opened')
        line = '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"bee://scene"}}'
        P.ask(line, 'bee://scene of the opened file', rid=3)
        P.tool('run_operator', {'id': 'file.save', 'arg': '$HOME/s2.bee'}, 'saved again', err=False)
        P.p.pump(0.5)
        p2 = os.path.join(P.p.home, 's2.bee')
        c2 = dict(beefile.chunks(p2)) if os.path.exists(p2) else {}
        tags = [b'OBJS', b'MESH', b'MATS', b'OMAT', b'MGRF', b'MODS', b'PRNT', b'LCAM', b'WRLD']
        apart = [t.decode() for t in tags if ch.get(t) != c2.get(t)]
        check(c2 and not apart, f'save -> open -> save: the same {b" ".join(tags).decode()} (apart: {apart})')
    finally:
        P.close()


# ---- permissions ----------------------------------------------------------------------

def s_perm():
    print('-- permissions: read-only, edit (default), files; refusals')
    for perm in ['read-only', 'readonly', 'edit', 'files', 'nonsense']:
        ro = perm.startswith('read')
        P = One(perm=perm)
        try:
            s0 = P.scene()
            _, _, r = P.tool('create_primitive', {'type': 'cone', 'name': 'Nope'}, f'{perm}: create_primitive', err=ro)
            if ro:
                check("permission denied: create_primitive needs the 'edit' permission and agents are set to 'read-only'" in (r or ''), f'{perm}: the refusal says why')
            P.tool('scene_summary', {}, f'{perm}: scene_summary (always allowed)', err=False)
            P.tool('op_view_toggle_grid', {'arg': ''}, f'{perm}: op_view_toggle_grid')
            P.tool('run_operator', {'id': 'file.save', 'arg': '$HOME/p.bee'}, f'{perm}: run_operator file.save', err=perm != 'files')
            P.tool('op_image_new', {'arg': 'I 4 4'}, f'{perm}: op_image_new (a new image is no file)', err=ro)
            P.tool('op_image_save', {'arg': '$HOME/i.png'}, f'{perm}: op_image_save (files)', err=perm != 'files')
            P.tool('undo', {}, f'{perm}: undo (edit)', err=ro)
            P.scene_ok(f'{perm}: the scene after')
            if ro:
                P.same_scene(s0, f'{perm}: nothing changed')
            P.tool('material_graph_set', {'name': 'M', 'graph': {'nodes': []}}, f'{perm}: material_graph_set (edit)', err=ro)
            P.tool('material_node_types', {}, f'{perm}: material_node_types (read)', err=False, show=False)
            check(os.path.exists(os.path.join(P.p.home, 'p.bee')) == (perm == 'files'), f'{perm}: the file written only with the files permission')
        finally:
            P.close()


# ---- undo: one step per request ----------------------------------------------------------

def s_undo():
    print('-- undo: one step per request, redo, failures part way')
    P = One()
    try:
        seq = [('create_primitive', {'type': 'cube', 'name': 'A', 'location': [1, 0, 0]}, False),
               ('set_transform', {'name': 'A', 'location': [2, 0, 0], 'scale': [2, 2, 2]}, False),
               ('op_object_modifier_add', {'arg': 'array'}, False),
               ('select', {'names': ['A', 'Cube']}, False),
               ('op_object_duplicate', {'arg': ''}, False),
               ('delete', {'names': ['Light']}, False),
               ('set_transform', {'name': 'Nope', 'location': [9, 9, 9]}, True),   # fails: no step
               ('create_primitive', {'type': 'nope'}, True)]                       # fails: no step
        states = [P.scene()]
        for name, args, err in seq:
            P.tool(name, args, f'{name}', err=err)
            if not err and name != 'select':   # (a selection alone: no step)
                states.append(P.scene())
        steps = len(states) - 1
        for k in range(steps):
            P.tool('undo', {}, f'undo {k + 1}', err=False)
            check(bare(P.scene()) == bare(states[steps - 1 - k]), f'undo {k + 1}: the scene before request {steps - k}')
        P.tool('undo', {}, 'one undo more than the requests: nothing to undo')
        check(bare(P.scene()) == bare(states[0]), 'the scene as at the start')
        for k in range(steps):
            P.tool('redo', {}, f'redo {k + 1}', err=False)
            check(bare(P.scene()) == bare(states[k + 1]), f'redo {k + 1}: the scene after request {k + 1}')
        # undo, then a new request: the redo steps go
        P.tool('undo', {}, 'undo once more', err=False)
        P.tool('create_primitive', {'type': 'sphere', 'name': 'B'}, 'a new request after an undo', err=False)
        sc = P.scene()
        P.tool('redo', {}, 'redo: nothing to redo')
        P.same_scene(sc, 'the scene as it was')
        P.p.tool('undo')
        check(bare(P.scene()) == bare(states[steps - 1]), 'undo of the request')
    finally:
        P.close()


# ---- the AI Activity editor in the window ------------------------------------------

def activity_rect(prog):
    """The AI Activity area's rectangle: ui_tree records its editor button (4, 2 into the area)."""
    t, _, _ = prog.tool('ui_tree')
    try:
        w = json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        return None
    a = [x for x in w if x['kind'] == 'editor' and x['label'] == 'AI Activity']
    return (a[0]['x'] - 4, a[0]['y'] - 2, a[0]['w'], 0) if a else None


def area_width(prog):
    t, _, _ = prog.tool('ui_tree')
    try:
        w = json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        return 0
    r = activity_rect(prog)
    # the widest row of widgets at the area's top: its header
    xs = [x['x'] + x['w'] for x in w if r and abs(x['y'] - r[1] - 2) < 4]
    return (max(xs) - r[0]) if xs else 0


def red_button(img, r):
    """The revert button: COL_REC pixels in the area (their centre, count)."""
    x0, y0 = r[0], r[1]
    pts = [(x, y) for y in range(y0, min(y0 + 40, img.size[1])) for x in range(x0, min(x0 + 1280, img.size[0]))
           if img.getpixel((x, y)) == (0xe5, 0x48, 0x4d)]
    if not pts:
        return None, 0
    return (sum(p[0] for p in pts) // len(pts), sum(p[1] for p in pts) // len(pts)), len(pts)


def click(prog, x, y):
    prog.f.enter(x, y)
    prog.f.motion(x, y)
    prog.f.pump(0.05)
    prog.f.button(0x110, True)
    prog.f.pump(0.05)
    prog.f.button(0x110, False)
    prog.pump(0.4)


US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53}
US_SHIFT = {'_': 12, '"': 40}


def console(prog, cmd):
    """The user types a command into the console (Enter, the text, Enter, Esc)."""
    prog.f.enter(600, 300)
    prog.f.key(28)
    for ch in cmd:
        prog.f.key(US_SHIFT[ch] if ch in US_SHIFT else US[ch], 1 if ch in US_SHIFT else 0)
    prog.f.key(28)
    prog.f.pump(0.2)
    prog.f.key(1)
    prog.pump(0.3)


def s_window():
    print('-- the AI Activity editor: shown, the one-click revert, the permission from the console')
    P = One()
    p = P.p
    try:
        p.tool('op_view_toggle_activity', {'arg': ''})
        p.pump(0.5)
        r = activity_rect(p)
        check(r is not None, f'view.toggle_activity shows the AI Activity area ({r})')
        if not r:
            return
        P.tool('set_transform', {'name': 'Nope'}, 'an error', err=True)
        P.tool('run_operator', {'id': 'file.save', 'arg': '$HOME/n.bee'}, 'a refusal', err=True)
        before = P.scene()
        P.tool('create_primitive', {'type': 'cone', 'name': 'Spike', 'location': [-3, 0, 2]}, 'a change', err=False)
        # the one-click revert: the red button, then the scene as before the change
        p.pump(0.5)
        c, n = red_button(p.image(), r)
        check(c is not None and n > 200, f'the revert button shown ({n} red pixels)')
        if c:
            click(p, c[0], c[1])
        sp = P.scene()
        check(sp and 'Spike' not in [x['name'] for x in sp['objects']], 'one click reverts the agent\'s change')
        P.same_scene(before, 'the scene as before it')
        p.pump(0.5)
        c, n = red_button(p.image(), r)
        check(c is None, 'no revert button when there is no agent\'s change')
        # maximized (it was the active area since the click): wide
        p.tool('op_area_maximize', {'arg': ''})
        p.pump(0.6)
        wo = activity_rect(p)
        im = p.image()
        check(wo is not None and wo[0] < 20 and P.p.alive(), f'the AI Activity maximized ({wo})')
        p.tool('op_area_maximize', {'arg': ''})
        p.pump(0.3)
        r = activity_rect(p) or r
        # the user's own change (the console): no revert button either
        P.tool('create_primitive', {'type': 'cube', 'name': 'A1'}, 'an agent\'s change first', err=False)
        n0 = len(P.scene()['objects'])
        console(p, 'create.sphere')
        check(len(P.scene()['objects']) == n0 + 1, 'the console\'s create.sphere made a sphere')
        p.pump(0.5)
        c, n = red_button(p.image(), r)
        check(c is None, 'no revert button when the last change is the user\'s')
        console(p, 'edit.undo')
        p.tool('undo')
        # the user sets the permission (the console): agents are refused at once
        console(p, 'agent.permission_read')
        _, _, rp = P.tool('create_primitive', {'type': 'cube', 'name': 'NoWay'}, 'after agent.permission_read in the console: refused', err=True)
        check(rp and "permission denied: create_primitive needs the 'edit' permission and agents are set to 'read-only'" in rp, 'it says so')
        P.tool('op_view_toggle_grid', {'arg': ''}, 'and an operator too')
        console(p, 'agent.permission_edit')
        P.tool('create_primitive', {'type': 'cube', 'name': 'Yes'}, 'after agent.permission_edit: allowed again', err=False)
        p.tool('undo')
        P.tool('select', {'names': ['Cube']}, 'select the Cube', err=False)
        P.tool('create_primitive', {'type': 'cube', 'name': 'Agent'}, 'an agent\'s change', err=False)
        t, _, _ = p.tool('op_edit_undo', {})
        check(t == 'ok\n  undo: Agent: create_primitive', f'op_edit_undo names the agent\'s step ({t!r})')
        f0 = p.frames()
        p.f.motion(400, 400)
        p.pump(0.5)
        check(p.alive() and p.frames() > f0, 'the window keeps drawing')
    finally:
        P.close()


# ---- every agent-safe operator as a tool -----------------------------------------------

# (the network, servers, other processes, play mode's locked pointer and long
# renders are left out: never the network in tests)
SKIP_PREFIX = ('co.', 'link.', 'vc.', 'ai.', 'play.')
SKIP = {'lib.sources', 'lib.source', 'lib.source_next', 'lib.refresh', 'lib.get', 'lib.stop', 'render.image',
        'render.start', 'render.animation', 'lib.thumbnails', 'lib.thumbnail', 'file.recover', 'help.welcome'}
ARGS = ['', '1', '-3.5', 'Cube', 'Cube 2', 'x y z', '"quoted text"', '$HOME/sweep.bee', 'nan', '999999', 'subsurf', 'Material']


def s_sweep():
    print('-- every agent-safe operator as op_<id>, random arguments: well formed answers, a sane scene, no crash')
    ids = re.findall(r'"([^"]+)"', open(os.path.join(ROOT, 'src', 'aisafe.zig')).read().split('ids =')[1].split('};')[0])
    ids = [i for i in ids if not i.startswith(SKIP_PREFIX) and i not in SKIP]
    rnd = random.Random(12)
    P = Prog(perm='files')
    crashes = bad = insane = slow = 0
    n = 0
    prev = ''
    try:
        for k, op in enumerate(ids * RUNS):
            if os.environ.get('MCP_TRACE'):
                print('    ', k, op, flush=True)
            if not P.alive():
                crashes += 1
                print(f'     BEEMODEL WENT at {prev}')
                P.close()
                P = Prog(perm='files')
            P.tool('op_file_new', {'arg': ''})
            P.tool('op_mode_object', {'arg': ''})
            arg = rnd.choice(ARGS)
            prev = f'{op} {arg!r}'
            line = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'op_' + op.replace('.', '_'), 'arguments': {'arg': arg}}}, separators=(',', ':'))
            rp = P.raw(line, timeout=30, tag=True)
            if P.slow > 2:
                slow += 1
                print(f'     slow: {prev}: {P.slow:.1f} s')
            n += 1
            w = wellformed(rp, 1)
            if w:
                bad += 1
                print(f'     {op} {arg!r}: {w}: {rp!r:.200}')
                continue
            sc = P.scene()
            if sc is None or not finite(sc) or len({o['name'] for o in sc['objects']}) != len(sc['objects']):
                insane += 1
                print(f'     {op} {arg!r}: the scene after it: {str(sc)[:200]}')
        if not P.alive():
            crashes += 1
    finally:
        P.close()
    check(crashes == 0 and bad == 0, f'{n} operator calls: BeeModel never went, every reply well formed ({crashes} crashes, {bad} bad replies)')
    check(insane == 0, f'and the scene after each reads back: names unique, numbers finite ({insane} not)')
    SWEEP.update(n=n, slow=slow)


# ---- the transport, fuzzed --------------------------------------------------------------

def rand_json(rnd, depth=0):
    """A random JSON value (as text): strings with escapes and UTF-8, numbers
    of every form, nesting."""
    k = rnd.random()
    if depth > 4 or k < 0.3:
        return rnd.choice(['true', 'false', 'null', '0', '-0', '1e5', '-2.5E-3', '123456789012345678901234567890',
                           '"' + rnd.choice(['', 'x', 'é', '\\u00e9\\u20ac', '\\"\\\\\\/\\b\\f\\n\\r\\t', 'a' * rnd.randint(0, 300), '\\ud83d\\ude00']) + '"'])
    if k < 0.65:
        return '[' + ','.join(rand_json(rnd, depth + 1) for _ in range(rnd.randint(0, 4))) + ']'
    keys = ['name', 'arguments', 'uri', 'id', 'method', 'params', 'protocolVersion', 'type', 'names', 'x', 'é']
    return '{' + ','.join('"%s":%s' % (rnd.choice(keys), rand_json(rnd, depth + 1)) for _ in range(rnd.randint(0, 4))) + '}'


READ_TOOLS = ['scene_summary', 'material_node_types', 'material_graph', 'nope', '', 'op_nope', 'run_operator', 'set_transform', 'create_primitive']


def rand_msg(rnd):
    """A random request: mostly well formed, some broken on purpose."""
    m = rnd.choice(['ping', 'initialize', 'tools/call', 'resources/read', 'resources/list', 'no/such', 'tools/call', 'prompts/x'])
    parts = []
    if rnd.random() < 0.9:
        parts.append('"jsonrpc":"2.0"')
    if rnd.random() < 0.85:
        parts.append('"id":' + rnd.choice(['1', '"s"', '-7.25e2', 'null', '{"a":[1]}', '[]', 'true']))
    if rnd.random() < 0.9:
        parts.append('"method":' + rnd.choice(['"%s"' % m, '5', 'null']))
    if m == 'tools/call' and rnd.random() < 0.9:
        # read-only tools and failures (no change to compare in the scene)
        args = rand_json(rnd) if rnd.random() < 0.5 else '{"name":%s,"names":["Cube"],"type":"nope"}' % rand_json(rnd, 3)
        parts.append('"params":{"name":"%s","arguments":%s}' % (rnd.choice(READ_TOOLS), args))
    elif rnd.random() < 0.5:
        parts.append('"params":' + rand_json(rnd))
    rnd.shuffle(parts)
    t = '{' + ','.join(parts) + '}'
    r = rnd.random()
    if r < 0.08:
        t = t[:rnd.randint(0, len(t))]                     # cut short
    elif r < 0.14:
        i = rnd.randint(0, len(t))
        t = t[:i] + rnd.choice(['}', ']', ',', '"', '\\', '\x01', 'x', ' ']) + t[i:]
    elif r < 0.18:
        t = ' \t' + t + ' \r'
    return t


def s_random():
    print('-- random JSON-RPC (valid and broken): well formed replies, the server alive')
    rnd = random.Random(99)
    P = One()
    bad = 0
    try:
        n = NFUZZ * RUNS
        for k in range(n):
            t = rand_msg(rnd)
            P.p.send(t.encode() + b'\n{"jsonrpc":"2.0","id":"sync","method":"ping"}\n')
            got = []
            synced = False
            while True:
                r = P.p.reply(5)
                if r is None:
                    break
                if r == b'{"jsonrpc":"2.0","id":"sync","result":{}}':
                    synced = True
                    break
                got.append(r.decode('utf-8', 'replace'))
            w = [wellformed(g) for g in got]
            if not synced or any(w) or len(got) > 1:
                bad += 1
                if bad <= 5:
                    print('     message:', t[:300])
                    print('     replies:', str(got)[:300], w, 'synced' if synced else 'no sync')
        check(bad == 0 and P.p.alive(), f'{n} random messages: at most one well formed reply each, the ping after it answered ({bad} not)')
        P.scene_ok('and the scene reads back')
    finally:
        P.close()


def rss_kb(pid):
    for line in open(f'/proc/{pid}/status'):
        if line.startswith('VmRSS:'):
            return int(line.split()[1])
    return 0


def s_fuzz():
    print('-- the transport fuzzed: garbage, oversized, partial lines, many clients, gone clients')
    P = Prog()
    rnd = random.Random(5)
    try:
        # garbage: random bytes, every line answered or not, the server alive
        for k in range(NFUZZ * RUNS):
            junk = bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 400))).replace(b'\n', b' ')
            P.send(junk + b'\n')
            if k % 25 == 0:
                P.send(b'{"jsonrpc":"2.0","id":"s","method":"ping"}\n')
                while True:
                    r = P.reply(5)
                    if r is None or b'"id":"s"' in r:
                        break
                    json.loads(r)
                if r is None:
                    break
        r = P.raw(tag=True, line='{"jsonrpc":"2.0","id":1,"method":"ping"}')
        check(r == '{"jsonrpc":"2.0","id":1,"result":{}}' and P.alive(), f'{NFUZZ * RUNS} lines of random bytes: answered as JSON, still serving')
        # a line too long for the buffer (256 KiB): that client goes, others stay
        s2 = P.connect()
        s2.setblocking(True)
        s2.settimeout(5)
        try:
            s2.sendall(b'{"x":"' + b'a' * (300 << 10))
        except OSError:
            pass
        P.pump(0.5)
        try:
            s2.setblocking(True)
            s2.settimeout(3)
            gone = s2.recv(10) == b''
        except socket.timeout:
            gone = False      # (still connected: the line was kept)
        except OSError:
            gone = True
        check(gone, 'a line over 256 KiB: that client is dropped')
        s2.close()
        r = P.raw(tag=True, line='{"jsonrpc":"2.0","id":2,"method":"ping"}')
        check(r == '{"jsonrpc":"2.0","id":2,"result":{}}', 'the other client still served')
        # a big line that fits: answered
        big = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_transform","arguments":{"name":"' + 'n' * (200 << 10) + '"}}}'
        r = P.raw(big, tag=True)
        check(r is not None and 'no object named ' + 'n' * 31 + '"' in r, 'a 200 KiB line: answered (the name read as 31 bytes)')
        # partial lines: a request a byte at a time
        line = b'{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scene_summary"}}\n'
        for c in line:
            P.send(bytes([c]))
            P.pump(0.002)
        r = P.reply(5)
        check(r is not None and r.startswith(b'{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\\"units\\"'), 'a request sent a byte at a time: one answer')
        # two requests in one write, one split over two
        P.send(b'{"jsonrpc":"2.0","id":5,"method":"ping"}\n{"jsonrpc":"2.0","id":6,"meth')
        P.pump(0.2)
        P.send(b'od":"ping"}\n')
        r1, r2 = P.reply(5), P.reply(5)
        check(r1 == b'{"jsonrpc":"2.0","id":5,"result":{}}' and r2 == b'{"jsonrpc":"2.0","id":6,"result":{}}', 'two in one write, one split: both answered in order')
        # many clients: four at a time (ours is one), the rest closed at once
        socks = [P.connect() for _ in range(6)]
        P.pump(0.5)
        alive = []
        closed = 0
        for s in socks:
            P.send(b'{"jsonrpc":"2.0","id":7,"method":"ping"}\n', s)
        P.pump(0.5)
        for s in socks:
            s.setblocking(True)
            s.settimeout(2)
            try:
                d = s.recv(100)
                closed += d == b''
            except socket.timeout:
                d = b''        # (neither served nor closed: left waiting)
            except OSError:
                d = b''
                closed += 1
            alive.append(d.startswith(b'{"jsonrpc"'))
        check(sum(alive) == 3 and closed == 3, f'four clients at most: three more served, the others closed at once ({sum(alive)} served, {closed} closed)')
        for s in socks:
            s.close()
        P.pump(0.5)
        socks = [P.connect() for _ in range(3)]
        ok = 0
        for s in socks:
            P.send(b'{"jsonrpc":"2.0","id":8,"method":"ping"}\n', s)
        P.pump(0.5)
        for s in socks:
            s.setblocking(True)
            s.settimeout(2)
            try:
                ok += s.recv(100).startswith(b'{"jsonrpc"')
            except OSError:
                pass
            s.close()
        check(ok == 3, 'the slots of gone clients are free again')
        # clients gone mid-request: a capture asked for, the socket closed at once
        for k in range(10):
            s = P.connect()
            P.send(b'{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"viewport_capture","arguments":{"area":"window"}}}\n', s)
            s.close()
            P.pump(0.05)
        P.pump(0.5)
        check(P.alive() and P.raw(tag=True, line='{"jsonrpc":"2.0","id":10,"method":"ping"}') == '{"jsonrpc":"2.0","id":10,"result":{}}', 'ten clients gone mid-capture: still serving')
        # a client that asks and never reads: dropped after 5 s, not a hang
        s = P.connect()
        t0 = time.time()
        for k in range(40):
            P.send(b'{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"viewport_capture","arguments":{"area":"window"}}}\n', s)
        frames0 = P.frames()
        P.pump(8)
        r = P.raw(tag=True, line='{"jsonrpc":"2.0","id":12,"method":"ping"}', timeout=20)
        check(r == '{"jsonrpc":"2.0","id":12,"result":{}}', f'a client that never reads its captures: dropped, the rest served ({time.time() - t0:.1f} s)')
        s.close()
        # the window still draws: input makes a frame
        f0 = P.frames()
        P.f.enter(500, 400)
        for x in range(500, 700, 20):
            P.f.motion(x, 400)
            P.pump(0.03)
        P.pump(0.5)
        check(P.frames() > f0, f'the window keeps drawing ({P.frames() - f0} frames after the fuzz)')
        # memory: the same requests again and again, the resident size steady
        mix = ['{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"scene_summary"}}',
                              '{"jsonrpc":"2.0","id":15,"method":"tools/list"}',
                              '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"material_node_types"}}',
                              '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"viewport_capture"}}',
                              '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"set_transform","arguments":{"name":"Cube","location":[1,2,3]}}}',
                              '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"undo"}}', 'garbage']
        for k in range(300):   # (the buffers grow to their size first)
            P.raw(tag=True, line=rnd.choice(mix))
        for k in range(200):   # (and the undo history fills its 128 steps)
            P.raw(tag=True, line='{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"set_transform","arguments":{"name":"Cube","location":[%d,0,0]}}}' % (k % 2))
        r0 = rss_kb(P.pid)
        for k in range(600):
            P.raw(tag=True, line=rnd.choice(mix))
        r1 = rss_kb(P.pid)
        check(P.alive() and r1 - r0 < 4096, f'600 more requests (after 300 the same): resident {r0 // 1024} -> {r1 // 1024} MiB (no leak)')
    finally:
        err = P.close()
        if err and ('panic' in err or 'leak' in err.lower()):
            print(err[-2000:])
            check(False, 'stderr has a panic or a leak')


# ---- beemodel --mcp-bridge --------------------------------------------------------------

def bridge_run(prog, lines, env_extra=None):
    """The bridge as an agent's host starts it: the requests on stdin (kept open
    until each answer came), the answers from stdout."""
    env = dict(os.environ, HOME=prog.home, XDG_RUNTIME_DIR=prog.home, XDG_CACHE_HOME=os.path.join(prog.home, 'cache'), PATH=STUBS + ':' + os.environ.get('PATH', ''))
    env.update(env_extra or {})
    b = subprocess.Popen([BIN, '--mcp-bridge'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.set_blocking(b.stdout.fileno(), False)
    out, buf = [], b''
    for line in lines:
        b.stdin.write(line.encode() + b'\n')
        b.stdin.flush()
        end = time.time() + 10
        while time.time() < end and b'\n' not in buf:
            prog.pump(0.02)
            try:
                d = os.read(b.stdout.fileno(), 1 << 20)
                if d:
                    buf += d
            except BlockingIOError:
                pass
        if b'\n' in buf:
            l, buf = buf.split(b'\n', 1)
            out.append(l.decode())
        else:
            out.append(None)
    b.stdin.close()
    try:
        b.wait(timeout=10)
    except subprocess.TimeoutExpired:
        b.kill()
        b.wait()
    return out, b.returncode


def s_bridge():
    print('-- beemodel --mcp-bridge: stdio relayed to the running app')
    P = One()
    p = P.p
    try:
        lines = ['{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}',
                 '{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"ping"}',
                 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_primitive","arguments":{"type":"cone","name":"Br"}}}',
                 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scene_summary"}}',
                 'not json']
        direct = [p.raw(lines[0]), p.raw('{"jsonrpc":"2.0","id":2,"method":"ping"}')]
        out, code = bridge_run(p, lines)
        ids = [1, 2, 3, 4, None]
        check(None not in out and all(not wellformed(r, i) for r, i in zip(out, ids)) and code == 0,
              f'through the bridge: {sum(r is not None for r in out)} of {len(lines)} answers, well formed, the ids back, exit {code}')
        check(out[:2] == direct, 'initialize and ping: the answers the socket gives')
        check(obj(p.scene(), 'Br') is not None and '\\"Br\\"' in (out[3] or ''), 'the bridge\'s create_primitive made Br, its scene_summary shows it')
        check(out[4] is not None and '-32700' in out[4], 'not JSON: a parse error')
        # BEEMODEL_SOCKET: another instance's socket by its path
        sock = [f for f in os.listdir(p.home) if f.startswith('beemodel-') and f.endswith('.sock')]
        o2, c2 = bridge_run(p, ['{"jsonrpc":"2.0","id":5,"method":"ping"}'], {'BEEMODEL_SOCKET': os.path.join(p.home, sock[0]) if sock else '/nope'})
        check(sock and o2 == ['{"jsonrpc":"2.0","id":5,"result":{}}'], f'BEEMODEL_SOCKET names the socket ({sock})')
        check(os.path.islink(os.path.join(p.home, 'beemodel.sock')) and os.readlink(os.path.join(p.home, 'beemodel.sock')) == os.path.join(p.home, sock[0]),
              'beemodel.sock links to beemodel-<pid>.sock')
    finally:
        P.close()
    # no app: it waits about 5 s and says so
    empty = tempfile.mkdtemp(prefix='e', dir=T)
    t0 = time.time()
    r = subprocess.run([BIN, '--mcp-bridge'], env=dict(os.environ, HOME=empty, XDG_RUNTIME_DIR=empty, XDG_CACHE_HOME=empty), input=b'', capture_output=True, timeout=30)
    check(r.returncode == 1 and b'no running BeeModel' in r.stderr, f'no app: exit 1, it says so ({time.time() - t0:.0f} s)')
    # the sockets when it ends
    p = Prog()
    home = p.home
    p.close()
    left = [f for f in os.listdir(home) if f.endswith('.sock')]
    print(f'     sockets left after a kill: {left} (a kill leaves them; the next start removes its own stale one)')


# ---- performance ------------------------------------------------------------------------

def s_perf():
    print('-- performance: scene_summary and viewport_capture on a big scene (a release build, one CPU)')
    rel = os.environ.get('MCP_REL')
    if not rel:
        print('     MCP_REL (a release build) not given: skipped')
        return
    # the big scene: made by BeeScript (--run), saved, opened through the tools
    d = tempfile.mkdtemp(prefix='perf', dir=T)
    path = os.path.join(d, 'big.bee')
    code = 'for i in 0..3000 {\n  n = add("sphere", "S" + i, i %% 60, 0, floor(i / 60))\n}\nop("file.save", "%s")\n' % path
    open(os.path.join(d, 'big.bees'), 'w').write(code)
    r = subprocess.run(['taskset', '-c', str(CPU), rel, '--run', os.path.join(d, 'big.bees')], env=dict(os.environ, HOME=d, XDG_RUNTIME_DIR=d, XDG_CACHE_HOME=d, BEEMODEL_NO_MCP='1'), capture_output=True, timeout=600)
    check(r.returncode == 0 and os.path.exists(path), f'the big scene written ({os.path.getsize(path) // 1024 if os.path.exists(path) else 0} KiB)')
    p = Prog(perm='files', binary=rel)
    try:
        p.tool('op_file_open', {'arg': path})
        p.pump(3)
        sc = None
        for _ in range(50):
            sc = p.scene()
            if sc and len(sc['objects']) > 3000:
                break
            p.pump(0.5)
        check(sc and len(sc['objects']) == 3003, f'the big scene opened: {len(sc["objects"]) if sc else 0} objects')
        for name, args, n in (('scene_summary', {}, 20), ('viewport_capture', {}, 10), ('viewport_capture', {'area': 'window'}, 10)):
            ts = []
            size = 0
            ok = True
            for _ in range(n):
                t0 = time.perf_counter()
                t, e, r = p.tool(name, args)
                ts.append(time.perf_counter() - t0)
                size = len(r or '')
                ok = ok and not wellformed(r, 1) and e is False
            ts.sort()
            print(f'     {name} {args.get("area", "")}: {ts[len(ts) // 2] * 1000:.1f} ms ({size // 1024} KiB)')
            check(ok, f'{name} {args.get("area", "")} on the big scene: {n} well formed answers')
    finally:
        p.close()


def main():
    t0 = time.time()
    try:
        for name, fn in [('proto', s_proto), ('tools', s_tools), ('mat', s_mat), ('files', s_files), ('perm', s_perm), ('undo', s_undo), ('window', s_window), ('sweep', s_sweep), ('random', s_random), ('fuzz', s_fuzz), ('bridge', s_bridge), ('perf', s_perf)]:
            if section(name):
                fn()
    finally:
        shutil.rmtree(T, True)
    print(f'mcp: {time.time() - t0:.0f} s, fails {len(FAILS)}')
    for f in FAILS:
        print('   ', f)


if __name__ == '__main__':
    main()
