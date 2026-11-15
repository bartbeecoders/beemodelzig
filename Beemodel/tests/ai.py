#!/usr/bin/env python3
"""The AI Assistant and Ask AI (ai.zig, aiproc.zig, aiask.zig; their prompts are Zui text areas),
with no network, no real AI program and no real key:

  * fake claude, grok and curl programs (tests/aifakes) first on PATH, in
    the test's temp dir: they log their argv, working directory, stdin,
    environment and the files they were handed, replay scripted streams and
    call back into the app over --mcp-bridge where the real tool would;
  * a fake OpenAI-compatible server on 127.0.0.1 (OpenRouter and Ollama);
  * BeeModel in the fake compositor (tests/wl_fake.py), with its own temp
    HOME, XDG folders and MCP socket; prompts typed in; checked: the
    transcript (ai.transcript and ai.copy), the argv and configuration files
    the CLIs got, the requests the server got, the scene and its undo steps
    afterwards, and how errors are handled (a child that crashes, hangs,
    writes garbage or huge lines; a curl that fails);
  * the headless driver (--mcp-listen, --ai-wait): the stream parsers fuzzed
    on the debug build, Stop's TERM then KILL, the files' modes.

    python3 tests/ai.py BIN [runs=1]

BEE_CPU (default 12) pins the program; AI_ONLY=cli,or,ask,... runs some
sections; AI_FUZZ (default 300) sets the fuzz's stream count.
"""
import json, math, os, random, re, shutil, signal, socket, stat, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own, all five XDG folders)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = int(os.environ.get('BEE_CPU', '12'))
ONLY = [x for x in os.environ.get('AI_ONLY', '').split(',') if x]
NFUZZ = int(os.environ.get('AI_FUZZ', '300'))
FAKES = os.path.join(HERE, 'aifakes')
FAILS = []
T = tempfile.mkdtemp(prefix='bai-', dir='/tmp')   # (short: unix socket paths)
os.environ['TMPDIR'] = T
tempfile.tempdir = T
os.environ.pop('OPENROUTER_API_KEY', None)          # (never a real key)
KEY = 'sk-or-fake-0123456789'
SYSPATH = '/usr/local/bin:/usr/bin:/bin'
HELD = []                                           # processes to kill at the end
PERF = []                                           # (what, seconds or frames a second)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def section(name):
    return not ONLY or name in ONLY


# ---- the fake OpenAI-compatible server -------------------------------------------------

import http.server

SEEN = []          # every request: path, auth, body (parsed), raw
SLOW = threading.Event()


def call(i, name, args, raw_args=None):
    return {'id': 'call_%d' % i, 'type': 'function',
            'function': {'name': name, 'arguments': raw_args if raw_args is not None else json.dumps(args)}}


class Server(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass                                    # (curl stopped mid-reply)

    def log_message(self, *a):
        pass

    def reply(self, code, obj, raw=None):
        b = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def who(self):
        seg = self.path.split('/')
        if len(seg) > 2 and seg[1] in ('o', 'p', 'h'):
            self.path = '/' + '/'.join(seg[2:])
            return seg[1]
        return '?'

    def do_GET(self):
        w = self.who()
        SEEN.append({'who': w, 'path': self.path, 'auth': self.headers.get('Authorization'), 'body': None})
        if self.path.endswith('/models'):
            return self.reply(200, {'object': 'list', 'data': [{'id': 'other:7b'}, {'id': 'test-local:1b'}]})
        if self.path.endswith('/key') and self.headers.get('Authorization') == 'Bearer ' + KEY:
            return self.reply(200, {'data': {'label': 'test', 'usage': 0}})
        self.reply(401, {'error': {'message': 'No auth credentials found', 'code': 401}})

    def do_POST(self):
        w = self.who()
        raw = self.rfile.read(int(self.headers['Content-Length']))
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        SEEN.append({'who': w, 'path': self.path, 'auth': self.headers.get('Authorization'), 'body': body, 'raw': raw.decode('utf-8', 'replace')})
        if 'fuzz' in raw.decode('utf-8', 'replace') and body is not None:
            return self.fuzz(body)
        if body is None:
            return self.reply(400, {'error': {'message': 'bad json'}})
        msgs = body['messages']
        user = [m['content'] for m in msgs if m['role'] == 'user'][-1]
        done = 0
        for m in reversed(msgs):
            if m['role'] == 'user':
                break
            done += m['role'] == 'tool'
        msg = {'role': 'assistant', 'content': None}
        if 'slowly' in user:
            time.sleep(3)
        if 'loop' in user:                          # never done: the step limit
            msg['tool_calls'] = [call(done, 'scene_summary', {})]
        elif 'htmlpage' in user:
            return self.reply(500, None, b'<html><body>Internal Server Error\nsecond line</body></html>')
        elif 'notobject' in user:
            return self.reply(200, None, b'[1, 2, 3]')
        elif 'errobj' in user:
            return self.reply(429, {'error': {'message': 'Rate limit exceeded:\nfree-models-per-day', 'code': 429}})
        elif 'errstr' in user:
            return self.reply(400, {'error': 'just a string'})
        elif 'nochoices' in user:
            return self.reply(200, {'id': 'x', 'choices': []})
        elif 'nomessage' in user:
            return self.reply(200, {'id': 'x', 'choices': [{'index': 0}]})
        elif 'hugereply' in user:
            return self.reply(200, None, b'{"pad":"' + b'x' * 5000000 + b'"}')
        elif 'badargs' in user and done == 0:
            msg['tool_calls'] = [call(0, 'scene_summary', None, '{not json'), call(1, 'select', {'names': ['Cube']}, None),
                                 {'id': 'call_2', 'type': 'function'},
                                 {'id': 'call_3', 'type': 'function', 'function': {'name': 'script_eval', 'arguments': {'code': 'print(7)'}}},
                                 call(4, 'no_such_tool', {}), call(5, 'op_file_save', {}),
                                 call(6, 'script_eval', {'code': 'x = "' + 'y' * 400 + '"\nprint(x)'})]
        elif 'world' in user:
            if done == 0:
                msg['tool_calls'] = [call(0, 'scene_summary', {})]
            elif done == 1:
                msg['tool_calls'] = [call(1, 'script_eval', {'code': 'add("cube", "House", 0, 1, 0)\nscale("House", 2, 1, 1.5)\nm = material("Stone")\nassign("House", m)\nprint("world", count())'})]
            else:
                msg['content'] = 'A stone house.'
        elif done == 0:
            msg['content'] = 'Let me look first.'
            msg['tool_calls'] = [call(0, 'scene_summary', {})]
        elif done == 1:
            code = 'for i in 0..4 { add("sphere", "Ring" + str(i), cos(i * 1.5708) * 3, 1, sin(i * 1.5708) * 3) }'
            msg['tool_calls'] = [call(1, 'script_eval', {'code': code}), call(2, 'select', {'names': ['Ring0']})]
        else:
            msg['content'] = 'Made a ring of 4 spheres.\nWant more?'
        self.reply(200, {'id': 'gen-1', 'model': body.get('model'),
                         'choices': [{'index': 0, 'finish_reason': 'stop', 'message': msg}]})


def fuzz_reply(seed, done):
    """A random reply for a request (orfuzz <seed>): valid answers, tool calls
    of every shape, broken JSON, wrong types."""
    r = random.Random(seed * 1000 + done)
    if done >= 3 or r.random() < 0.15:
        return {'choices': [{'message': {'role': 'assistant', 'content': 'enough %d' % seed}}]}
    pick = r.randrange(12)
    if pick == 0:
        return b'{"choices":[' + bytes(r.randrange(256) for _ in range(r.randrange(200)))
    if pick == 1:
        return {'choices': r.choice([None, 1, 'x', [], [None], [{}], [{'message': None}], [{'message': {'content': 5}}]])}
    if pick == 2:
        return {'error': r.choice([None, 'x', {}, {'message': r.choice(['', 'boom', 'a\nb' * 50, 7])}])}
    calls = []
    for k in range(r.randrange(1, 5)):
        fn = r.choice(['scene_summary', 'select', 'script_eval', 'create_primitive', 'set_transform', 'nope', '', 'op_x', 'undo'])
        args = r.choice(['{}', '{"names":["Cube"]}', '{"code":"print(%d)"}' % k, '{"type":"cube","name":"F%d"}' % k, '{', '"str"', '[1]', '', None,
                         {'code': 'add("sphere", "S%d")' % k}, '{"name":"Cube","location":[%d,0,0]}' % k])
        c = {'id': r.choice(['c%d' % k, '', None, 5]), 'type': 'function'}
        if r.random() < 0.9:
            c['function'] = {'name': fn}
            if args is not None:
                c['function']['arguments'] = args
        calls.append(c)
    msg = {'role': 'assistant', 'content': r.choice([None, '', 'thinking %d' % seed, 'x\ty\rz'])}
    msg['tool_calls'] = r.choice([calls, calls, calls, [], None, 'x'])
    return {'choices': [{'message': msg}]}


def _fuzz(self, body):
    msgs = body['messages']
    user = [m['content'] for m in msgs if m['role'] == 'user'][-1]
    seed = int(re.findall(r'orfuzz (\d+)', user)[0]) if re.findall(r'orfuzz (\d+)', user) else 0
    done = sum(1 for m in msgs if m['role'] == 'tool')
    out = fuzz_reply(seed, done)
    if isinstance(out, bytes):
        return self.reply(200, None, out)
    return self.reply(200, out)


Server.fuzz = _fuzz

SRV = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
threading.Thread(target=SRV.serve_forever, daemon=True).start()
PORT = SRV.server_port
DEAD_PORT = None
_s = socket.socket()
_s.bind(('127.0.0.1', 0))
DEAD_PORT = _s.getsockname()[1]
_s.close()                                          # (nothing listens there)


# ---- the program ------------------------------------------------------------------------

US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51, ';': 39, "'": 40, '[': 26, ']': 27, '\\': 43, '`': 41}
US_SHIFT = {'_': 12, '(': 10, ')': 11, '"': 40, '+': 13, '{': 26, '}': 27, '*': 9, '<': 51, '>': 52,
            '#': 4, '%': 6, '!': 2, ':': 39, '?': 53, '@': 3, '$': 5, '^': 7, '&': 8, '|': 43, '~': 41}


def project(p, canvas=(208, 80, 1024, 633), yaw=0.7853982, pitch=0.5, dist=18.0):
    """A world point on screen in the default view (1280x800)."""
    sy, cy, sp, cp = math.sin(yaw), math.cos(yaw), math.sin(pitch), math.cos(pitch)
    right = (cy, 0, -sy)
    up = (-sp * sy, cp, -sp * cy)
    fwd = (-cp * sy, -sp, -cp * cy)
    eye = [-fwd[i] * dist for i in range(3)]
    d = [p[i] - eye[i] for i in range(3)]
    dot = lambda a, b: sum(a[i] * b[i] for i in range(3))
    x0, y0, x1, y1 = canvas
    f = (y1 - y0) * 1.07
    z = dot(d, fwd)
    return (int((x0 + x1) / 2 + f * dot(d, right) / z), int((y0 + y1) / 2 - f * dot(d, up) / z))


def make_bin(home, real_curl=None):
    b = os.path.join(home, 'bin')
    os.makedirs(b, exist_ok=True)
    for n in ('claude', 'grok'):
        os.symlink(os.path.join(FAKES, 'fake_cli.py'), os.path.join(b, n))
    os.symlink(os.path.join(FAKES, 'fake_curl.py'), os.path.join(b, 'curl'))
    return b


class Prog:
    """BeeModel in its fake compositor, an MCP client on its socket, fake
    AI programs first on its PATH."""

    def __init__(self, prefs=(), secret=None, env=None, size=(1280, 800)):
        self.home = tempfile.mkdtemp(prefix='h', dir=T)
        cfgdir = os.path.join(self.home, '.config', 'beemodel-zig')
        os.makedirs(cfgdir)
        if callable(prefs):
            prefs = prefs()
        if prefs:
            with open(os.path.join(cfgdir, 'prefs'), 'w') as f:
                f.write(''.join(p + '\n' for p in prefs))
        if secret is not None:
            p = os.path.join(cfgdir, 'secrets')
            with open(p, 'w') as f:
                f.write('openrouter_key %s\n' % secret)
            os.chmod(p, 0o600)
        self.bin = make_bin(self.home)
        e = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0', 'PATH': self.bin + ':' + SYSPATH}
        e.update(env or {})
        from wl_fake import Fake
        e.update(HOME=self.home, XDG_RUNTIME_DIR=self.home, XDG_CACHE_HOME=os.path.join(self.home, 'cache'))
        self.f = Fake(BIN, size=size, env=e)
        self.f.until(lambda: self.f.frames > 0, 10)
        self.f.enter(600, 300)
        self.f.motion(600, 300)
        self.pid = self.f.proc.pid
        HELD.append(self.f.proc)
        os.sched_setaffinity(self.pid, {CPU})
        self.pump(0.3)
        self.s = self.connect()
        self.buf = b''
        self.seq = 0

    def pump(self, t=0.05):
        self.f.pump(t)

    def alive(self):
        return self.f.proc.poll() is None

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(80):
            try:
                s.connect(os.path.join(self.home, 'beemodel.sock'))
                break
            except OSError:
                self.pump(0.1)
        s.setblocking(False)
        return s

    def call(self, method, params=None, timeout=10.0):
        self.seq += 1
        rid = 'q%d' % self.seq
        m = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params is not None:
            m['params'] = params
        try:
            self.s.sendall((json.dumps(m) + '\n').encode())
        except OSError:
            return None
        end = time.time() + timeout
        while time.time() < end:
            while b'\n' in self.buf:
                ln, self.buf = self.buf.split(b'\n', 1)
                try:
                    r = json.loads(ln.decode('utf-8', 'surrogateescape'))
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

    def tool(self, name, args=None, timeout=10.0):
        r = self.call('tools/call', {'name': name, 'arguments': args or {}}, timeout)
        res = (r or {}).get('result', {})
        return (res.get('content') or [{}])[0].get('text', ''), res.get('isError')

    def q(self, code):
        return (self.tool('script_eval', {'code': code})[0] or '').strip()

    def scene(self):
        t, _ = self.tool('scene_summary')
        try:
            return json.loads(t)
        except (TypeError, ValueError):
            return None

    def names(self):
        s = self.scene()
        return [o['name'] for o in s['objects']] if s else None

    def key(self, code, mods=0):
        self.f.key(code, mods)

    def type(self, text):
        for ch in text:
            sh = ch in US_SHIFT or ch.isupper()
            code = US_SHIFT[ch] if ch in US_SHIFT else US[ch.lower()]
            if sh:
                self.f.mods(1)
            self.f.serial += 1
            self.f.send(self.f.keyboard, 3, b''.join(x.to_bytes(4, 'little') for x in (self.f.serial, 1, code, 1)))
            self.f.serial += 1
            self.f.send(self.f.keyboard, 3, b''.join(x.to_bytes(4, 'little') for x in (self.f.serial, 1, code, 0)))
            if sh:
                self.f.mods(0)
        self.f.pump(0.1)

    def move(self, x, y):
        self.f.motion(x, y)
        self.pump(0.03)

    def click(self, x, y, btn=0x110, mods=0):
        if mods:
            self.f.mods(mods)
        self.f.click(x, y, btn)
        if mods:
            self.f.mods(0)
        self.pump(0.1)

    def widgets(self):
        t, _ = self.tool('ui_tree')
        try:
            return json.loads(t).get('widgets', [])
        except (TypeError, ValueError):
            return []

    def widget(self, name, kind=None, last=False):
        got = None
        for w in self.widgets():
            if w['name'] == name and (kind is None or w['kind'] == kind):
                if not last:
                    return w
                got = w
        return got

    def click_widget(self, name, kind=None, last=False):
        w = self.widget(name, kind, last)
        if w:
            self.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        return w

    def toast(self):
        for w in self.widgets():
            if w['kind'] == 'toast':
                return w.get('label') or ''
        return ''

    def transcript(self):
        t, _ = self.tool('op_ai_transcript')
        return [ln for ln in (t or '').split('\n') if ln.startswith('$ ')]

    def wait_idle(self, secs=25):
        end = time.time() + secs
        t = self.transcript()
        while time.time() < end:
            if t and 'idle' in t[0]:
                break
            self.pump(0.1)
            t = self.transcript()
        self.pump(0.15)
        return t

    def clipboard(self):
        return self.f.ask_source().decode('utf-8', 'replace')

    def runs(self, name):
        p = os.path.join(self.home, name + '.runs.jsonl')
        return [json.loads(ln) for ln in open(p)] if os.path.exists(p) else []

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            self.f.close()
        except Exception:
            pass


class Solo:
    """The program and the steps the sections take with it."""

    def __init__(self, **kw):
        self.p = Prog(**kw)

    def close(self):
        self.p.close()

    def mode(self):
        self.p.key(57, 5)                           # Ctrl+Shift+Space: ai.mode
        self.p.pump(0.3)

    def send(self, text):
        """Typed into the prompt (ai.mode first: the caret in it), Enter."""
        g = self.p
        g.key(57, 5)
        g.pump(0.2)
        g.type(text)
        g.key(28)
        g.pump(0.2)

    def wait(self, secs=25):
        return self.p.wait_idle(secs)

    def ended(self, label, tp, scene=True):
        """The request ended (idle), the program runs on, the scene reads back."""
        ok = bool(tp) and 'idle' in tp[0] and self.p.alive() and (not scene or self.p.scene() is not None)
        check(ok, f'{label}: the request ended, the program runs on' + (', the scene reads back' if scene else ''))
        if not ok:
            print('     transcript:', repr(tp[-4:] if tp else tp)[:600])
        return ok


# =========================================================================================
# The CLIs: Claude Code and the Grok CLI
# =========================================================================================

WANT = {
    'build a tower': ['A Looking at the scene first.', 'scene_summary {}', 'R   = built ', 'A Built a tower of 3 cubes.', 'A Ask for a roof next.'],
    'garbage please': ['N plain text output', 'N {not json', 'A tab here and a CR', 'A done with the garbage'],
    'please fail': ['N the fake failed on purpose', 'N and said so on stderr', ' ended with exit code 3'],
    'crash now': [' ended with exit code -1'],
    'maxturns reached': ['N Stopped after 100 turns (Preferences > AI > Turns at most).'],
    'broken run': ['E Something broke'],
    'toolerr calls': ['E   = '],
    'longtool calls': ['R     b', 'R     c yyyy'],
    'multi lines': ['A Third line after an empty one'],
    'noeol stream': ['A no newline at the end', 'E the last line'],
    'huge lines': ['N   (a message too long to show, such as an image, was left out)', 'A after 600000'],
    'orphan child': ['A Left a child behind.'],
    'flood lines': ['A line 2999 of the flood, with some words to make it longer'],
}


def s_cli():
    print('-- the CLIs: Claude Code and the Grok CLI, fake streams')
    P = Solo()
    g = P.p
    try:
        P.mode()
        names = {w['name'] for w in g.widgets()}
        check('ai.prompt' in names, 'Ctrl+Shift+Space makes the AI workspace, the prompt shown')
        modes = list(WANT)[:1] + ['build again'] + list(WANT)[1:]
        for conn in ('claude', 'grok'):
            if conn == 'grok':
                pick_connection(g, 1)
            for k, word in enumerate(modes):
                if word in ('flood lines', 'huge lines'):
                    # how long the stream takes to read
                    g.key(57, 5)
                    g.pump(0.2)
                    g.type(word)
                    t0 = time.time()
                    g.key(28)
                    tp = g.wait_idle(60)
                    PERF.append((f'{conn} {word}: Enter to idle (s)', time.time() - t0))
                else:
                    P.send(word)
                    tp = P.wait()
                P.ended(f'{conn} "{word}"', tp)
                tx = '\n'.join(tp)
                check('mcp__' not in tx, f'{conn} "{word}": tool names shown without the MCP prefix')
                if word == 'huge lines':
                    check(not any('QQQQ' in t for t in tp), f'{conn} "{word}": no piece of a line too long is shown')
                for w in WANT.get(word, []):
                    if not w in tx:
                        check(False, f'{conn} "{word}": the transcript has {w!r}')
                        print('     port:', repr(tx[-600:]))
                        break
                rp = g.runs(conn)
                if rp:
                    ap = rp[-1]['args']
                    if k == 0:
                        check('--resume' not in ap and '-r' not in ap, f'{conn}: a first request starts a new session')
                        check('--mcp-bridge' in (rp[-1].get('cfg') or '') and BIN in (rp[-1].get('cfg') or '') and g.home in (rp[-1].get('cfg') or ''),
                              f'{conn}: its configuration names this program as the bridge, for this instance\'s socket')
                        check(rp[-1].get('cfg_mode') == 0o600, f'{conn}: the configuration file is 0600 ({oct(rp[-1].get("cfg_mode", 0))})')
                        check(rp[-1]['stdin_dev'] and rp[-1]['stdin'] == '' and rp[-1]['stdout_is_stderr'],
                              f'{conn}: stdin is /dev/null, stdout and stderr one pipe')
                        # one undo step for the request: undo, redo
                        base = 'Tower' if conn == 'claude' else 'Grok'
                        before = g.names() or []
                        ur = g.tool('undo')[0] or ''
                        check(f'Agent: {word}' in ur, f'{conn}: the undo step is named for the request ({ur.strip()[:80]!r})')
                        sp = g.scene()
                        check(sp and not any(o['name'].startswith(base) for o in sp['objects']), f'{conn}: undo takes the whole request back (three cubes, two tool calls)')
                        g.tool('redo')
                        check(g.names() == before and any(n.startswith(base) for n in before), f'{conn}: redo puts the request back ({len(before)} objects)')
                    if word == 'build again':
                        flag = '--resume' if conn == 'claude' else '-r'
                        check(flag in ap and ap[ap.index(flag) + 1] == f'sess-{conn}-1', f'{conn}: a follow-up resumes the session ({flag} sess-{conn}-1)')
                else:
                    check(False, f'{conn} "{word}": the fake ran ({len(rp)})')
        # a prompt of several lines: Shift+Enter starts a line, the field grows
        g.key(57, 5)
        g.pump(0.2)
        h1 = (g.widget('ai.prompt') or {}).get('h', 0)
        g.type('two floors')
        g.key(28, 1)                                # Shift+Enter
        g.type('and a flat roof')
        g.pump(0.2)
        h2 = (g.widget('ai.prompt') or {}).get('h', 0)
        g.key(103)                                  # Up, Home: that line's start
        g.key(102)
        g.type('with ')
        g.key(28)
        g.pump(0.3)
        h3 = (g.widget('ai.prompt') or {}).get('h', 0)
        P.wait()
        ap = g.runs('grok')[-1]['args']
        check(ap[ap.index('-p') + 1] == 'with two floors\nand a flat roof', f'Shift+Enter starts a line; Up / Home go by line ({ap[ap.index("-p") + 1]!r})')
        check(h1 > 0 and h2 > h1 and h3 == h1, f'the prompt grows with its lines, and is one line again once sent (heights {(h1, h2, h3)})')
        # the whole conversation through Copy (ai.copy): every entry, as shown
        g.key(57, 5)
        g.pump(0.2)
        w = g.widget('Copy')
        if w:
            g.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
            g.pump(0.3)
        clip = g.clipboard()
        check(len(clip) > 2000 and 'line 2999 of the flood' in clip, f'Copy: it holds the conversation (its newer half after the flood: {len(clip)} bytes)')
        # New Conversation: the session goes, the transcript is empty
        g.click_widget('New')
        tp = g.transcript()
        check(tp == ['$ ai: idle 0'], f'New: the transcript is empty ({tp[:2]})')
        P.send('build a tower')
        P.wait()
        ap = g.runs('grok')[-1]['args']
        check('-r' not in ap, 'New: the next request starts a new session')
        # Stop: a slow one, then one that ignores TERM (KILL after a few ticks)
        for word in ('slow please', 'termignore please'):
            P.send(word)
            g.pump(0.6)
            busy = g.transcript()[0]
            check('busy' in busy, f'"{word}": busy while it runs ({busy})')
            if word == 'slow please':
                n0, t0 = g.f.frames, time.time()
                for i in range(25):
                    g.move(300 + 4 * i, 400 - 2 * i)
                fps = (g.f.frames - n0) / (time.time() - t0)
                PERF.append(('frames a second while the AI works (the pointer moving)', fps))
                check(fps > 10, f'while it works the window keeps drawing ({fps:.0f} frames a second)')
            w = g.widget('Stop')
            if w:
                g.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
            t1 = time.time()
            tp = P.wait(10)
            took = time.time() - t1
            check(w is not None and tp[-1] == '$ N Stopped.' and 'idle' in tp[0] and took < 3, f'"{word}": Stop ends the child ({took * 1000:.0f} ms)')
        # busy: a second prompt while one runs is refused
        P.send('slow again')
        g.pump(0.4)
        P.send('another one')
        msg = g.toast()
        check('still working' in msg, f'a prompt while the AI works: refused, it says the AI is still working ({msg!r})')
        g.click_widget('Stop')
        P.wait(10)
        check(not any('another one' in t for t in g.transcript()), 'the refused prompt is not in the transcript')
        # undo while a request runs (the step it makes stays one), then Stop
        g.tool('select', {'names': []})
        P.send('slow, with an undo')
        g.pump(0.4)
        g.key(44, 4)                                # Ctrl+Z while it works
        g.pump(0.2)
        g.click_widget('Stop')
        tp = P.wait(10)
        P.ended('Ctrl+Z while the AI works, then Stop', tp)
        g.tool('undo')
        check(g.alive() and g.scene() is not None, 'and undo after it: the scene reads back')
        # a click outside the Ask box closes it: typing goes elsewhere again
        e = project((-6, 0, 6))
        g.key(104, 4)                               # Ctrl+PageUp: back to Modeling
        g.pump(0.3)
        g.move(*e)
        g.click(e[0], e[1], 0x111, mods=8)
        g.pump(0.2)
        g.click(*e)
        g.pump(0.2)
        g.key(57, 5)                                # Ctrl+Space+Shift: a shortcut again, not typing
        g.pump(0.3)
        check(bool(g.widget('ai.prompt')), 'a click outside the Ask box: the keys are shortcuts again (Ctrl+Shift+Space)')
    finally:
        P.close()
    print('-- a program that is not there; the MCP server off')
    P = Solo(prefs=['claude_path /nonexistent/claude', 'grok_path /nonexistent/grok'])
    try:
        P.send('build a tower')
        P.wait()
        pick_connection(P.p, 1)
        P.send('build a tower')
        tp = P.wait()
        P.ended('a missing program', tp)
        cut = lambda t: '$ E ' + t[:80]
        check(cut('Claude Code was not found: install it, or set its program in Preferences > AI.') in tp
              and cut('Grok was not found: install it, or set its program in Preferences > AI.') in tp, 'it says which, and where to set it')
        check(not P.p.runs('claude') and not P.p.runs('grok'), 'nothing was run')
    finally:
        P.close()


def or_prefs(port=None, steps=4):
    def f():
        pt = port or PORT
        return ['openrouter_url http://127.0.0.1:%d/p/api/v1' % pt, 'openrouter_steps %d' % steps,
                'openrouter_model test/model', 'ollama_url http://127.0.0.1:%d/p/ollama/v1/' % pt,
                'ollama_model test-local:1b', 'ollama_steps 3', 'ai_connection 2']
    return f


def seen(who, n0):
    return [x for x in SEEN[n0:] if x['who'] == who]


OR_WANT = {
    'make a ring': ['A Let me look first.', 'T   scene_summary {}', 'T   script_eval {"code":', 'T   select {"names": ["Ring0"]}', 'A Made a ring of 4 spheres.', 'A Want more?'],
    'loop forever': ['N Stopped after 4 steps (the limit is in Preferences > AI).'],
    'htmlpage': ["E OpenRouter's reply was not understood: <html><body>Internal Server Error"],
    'notobject': ["E OpenRouter's reply was not understood: [1, 2, 3]"],
    'errobj': ['E OpenRouter: Rate limit exceeded:', 'E             free-models-per-day'],
    'errstr': [],
    'nochoices': ['E OpenRouter gave no answer.'],
    'nomessage': ['E OpenRouter gave no answer.'],
    'badargs': ['T   scene_summary {}', 'T   no_such_tool {}', 'T   op_file_save {}', 'T   script_eval {"code": "print(7)"}'],
    'hugereply': ["E OpenRouter's reply was not understood: {\"pad\":\"xxxx"],
    'world': ['A A stone house.'],
}


def s_or():
    print('-- OpenRouter (and Ollama): the tool loop in-process, curl through files; a fake server')
    P = Solo(prefs=or_prefs(), secret=KEY)
    g = P.p
    try:
        P.mode()
        for word in OR_WANT:
            n0 = len(SEEN)
            P.send(word + ' please')
            tp = P.wait(40)
            P.ended(f'"{word}"', tp)
            tx = '\n'.join(tp)
            for w in OR_WANT[word]:
                if w not in tx:
                    check(False, f'"{word}": the transcript has {w!r}')
                    print('     port:', repr(tx[-500:]))
                    break
            rp = seen('p', n0)
            good = [b for b in rp if b['path'] == '/api/v1/chat/completions' and b['auth'] == 'Bearer ' + KEY
                    and isinstance(b['body'], dict) and b['body'].get('model') == 'test/model' and isinstance(b['body'].get('messages'), list)]
            check(len(rp) > 0 and len(good) == len(rp), f'"{word}": every request: JSON with the model, the messages, the path and the key ({len(good)} of {len(rp)})')
            if word == 'loop forever':
                check(len(rp) == 4, f'the step limit (openrouter_steps 4): 4 requests ({len(rp)})')
            if word == 'make a ring':
                b0 = rp[0]['body']
                tools = [t['function']['name'] for t in b0['tools']]
                check(rp[0]['auth'] == 'Bearer ' + KEY and b0['model'] == 'test/model' and b0['messages'][0]['role'] == 'system'
                      and 'script_eval' in tools and 'run_operator' in tools and not any(n.startswith('op_') for n in tools),
                      f'the first request: the key, the model, the instructions, the curated tools as functions ({len(tools)})')
                check(all(t.get('type') == 'function' and t['function'].get('name') and t['function'].get('description')
                          and isinstance(t['function'].get('parameters'), dict) for t in b0['tools']) and len(set(tools)) == len(tools),
                      'each tool offered: a name of its own, a description and parameters')
                last = rp[-1]['body']['messages']
                try:
                    whole = 'objects' in json.loads(last[3]['content'])
                except (ValueError, TypeError, KeyError, IndexError):
                    whole = False
                check(whole, 'a tool result goes back whole (scene_summary\'s JSON reads)')
                check([m['role'] for m in last] == ['system', 'user', 'assistant', 'tool', 'assistant', 'tool', 'tool'] and last[3]['tool_call_id'] == 'call_0'
                      and '"objects"' in last[3]['content'], 'the conversation sent back: each tool call answered with its result')
                cr = g.runs('curl')[-1]
                check(cr.get('hdr_mode') == 0o600 and cr.get('hdr_dir_mode') == 0o700 and cr.get('body_mode') == 0o600 and KEY in cr.get('hdr', ''),
                      f'curl gets the key in a header file only the user can read ({oct(cr.get("hdr_mode", 0))} in {oct(cr.get("hdr_dir_mode", 0))})')
                check(not any(KEY in a for r in g.runs('curl') for a in r['args']), 'the key is never on curl\'s command line')
                # Revert: one click takes the request back
                g.click_widget('Revert')
                g.pump(0.2)
                sp = g.scene()
                check(sp and not any(o['name'].startswith('Ring') for o in sp['objects']), 'Revert takes the OpenRouter request back in one step')
        # Stop while curl waits
        P.send('slowly make a ring')
        g.pump(0.8)
        g.click_widget('Stop')
        tp = P.wait(10)
        check(tp[-1] == '$ N Stopped.' and 'idle' in tp[0], f'Stop while curl waits: it says Stopped. ({tp[-1:]})')
        # New Conversation: the instructions again
        g.click_widget('New')
        n0 = len(SEEN)
        P.send('build a world')
        P.wait(30)
        rp = seen('p', n0)
        check(len(rp) == 3 and len(rp[0]['body']['messages']) == 2, 'New: the next request starts from the instructions again')
        # Ollama: the same loop, local, no key, thinking off
        g.click_widget('New')
        pick_connection(g, 3)
        n0 = len(SEEN)
        P.send('make a ring')
        tp = P.wait(30)
        P.ended('Ollama', tp)
        rp = seen('p', n0)
        check(len(rp) == 3 and all(x['path'] == '/ollama/v1/chat/completions' and x['auth'] is None for x in rp)
              and all(x['body']['model'] == 'test-local:1b' and x['body'].get('reasoning_effort') == 'none' for x in rp),
              f'Ollama: three requests to the local address, no key, thinking off ({len(rp)})')
        P.send('loop forever')
        tp = P.wait(30)
        check(tp[-1].startswith('$ N Stopped after 3 steps'), f'Ollama: its own step limit (3) ({tp[-1:]})')
    finally:
        P.close()
    print('-- OpenRouter: no key; curl fails; Ollama not running')
    P = Solo(prefs=or_prefs(port=DEAD_PORT))
    try:
        P.send('make a ring')
        tp = P.wait()
        check('$ E No OpenRouter key: set it in Preferences > AI (or OPENROUTER_API_KEY).' in tp and not P.p.runs('curl'), 'no key: it says where to set one, sends nothing')
    finally:
        P.close()
    P = Solo(prefs=or_prefs(port=DEAD_PORT), secret=KEY)
    try:
        P.send('make a ring')
        tp = P.wait()
        check(any(t.startswith('$ E The request to OpenRouter failed: curl: (7)') for t in tp), f'curl fails (nothing listens): it says the request failed, with curl\'s words ({tp[-1:]})')
        pick_connection(P.p, 3)
        P.send('make a ring')
        tp = P.wait()
        check(any('(is it running? ollama serve)' in t for t in tp), 'Ollama not running: is it running?')
    finally:
        P.close()


def s_prefs():
    print('-- Preferences > AI: the Test buttons, the key kept in the secrets file')
    P = Solo(prefs=or_prefs())
    g = P.p
    try:
        g.key(51, 4)                                # Ctrl+, : the Preferences
        g.pump(0.3)
        g.click_widget('AI', 'button', True)
        g.pump(0.3)
        # the key, typed in
        ws = [x for x in g.widgets() if x['kind'] == 'text' and 600 < x['x'] < 1000]
        ws.sort(key=lambda x: x['y'])
        # (the page's text rows: Also tell the AI, Program, Model, Program, Model, API key ...)
        w = ws[5] if len(ws) > 5 else None
        if w:
            g.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
            g.type(KEY)
            g.key(28)
            g.pump(0.2)
        sec = os.path.join(g.home, '.config', 'beemodel-zig', 'secrets')
        pp = os.path.join(g.home, '.config', 'beemodel-zig', 'prefs')
        prefs = open(pp).read() if os.path.exists(pp) else ''
        check(os.path.exists(sec) and KEY in open(sec).read() and stat.S_IMODE(os.stat(sec).st_mode) == 0o600 and KEY not in prefs,
              'the key typed in Preferences > AI: kept only in the 0600 secrets file')
        for _ in range(20):                         # (a frame or two after Enter)
            shown = [x for x in g.widgets() if KEY in str(x.get('label')) + str(x.get('value')) + x['name']]
            if not shown:
                break
            g.pump(0.1)
        check(not shown, 'the key is not shown once kept (the field shows the hint (set))')
        if shown:
            print('     shown in:', repr(shown)[:400])
        for label, want in (('Test Claude Code', 'N Claude Code: 9.9.9 (Claude Code)'),
                            ('Test Grok', 'N Grok: grok 9.9.9'),
                            ('Test OpenRouter', 'N OpenRouter: the key works'),
                            ('Test Ollama', 'N Ollama: it answers and has the model')):
            w = g.widget(label)
            for d in (10, 10, 10, -10, -10, -10, -10, -10, -10):
                if w and w['y'] < 700:
                    break
                g.move(w['x'] + w['w'] // 2 if w else 640, 400)
                g.f.send(g.f.pointer, 4, b''.join(x.to_bytes(4, 'little') for x in (1, 0)) + (int(3 * 256 * 15)).to_bytes(4, 'little'))
                g.pump(0.2)
                w = g.widget(label)
            if w:
                g.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
            for _ in range(30):
                g.pump(0.1)
                if want in '\n'.join(g.transcript()):
                    break
            tp = g.transcript()
            check(want in '\n'.join(tp), f'{label}: {want[2:]}')
    finally:
        P.close()


def s_ask():
    print('-- Ask AI about the selection: the box, what is sent, Only the selection, history, edit mode')
    empty = project((-6, 0, 6))
    P = Solo()
    g = P.p
    try:
        def alt_rclick(xy):
            g.move(*xy)
            g.click(xy[0], xy[1], 0x111, mods=8)
            g.pump(0.3)

        def boxed():
            return any(w['name'] == 'ask.prompt' for w in g.widgets())

        def sent():
            r = g.runs('claude')
            a = r[-1]['args'] if r else []
            return a[a.index('-p') + 1] if '-p' in a else ''

        def ask(text, xy=empty):
            alt_rclick(xy)
            g.type(text)
            g.key(28)
            g.pump(0.2)
            return P.wait()

        g.tool('select', {'names': ['Cube']})
        alt_rclick(empty)
        check(boxed(), 'Alt+right-click in the viewport opens the box')
        sp = g.q('print(issel("Cube"), active())')
        check(sp.split()[:1] == ['1'], f'nothing under the pointer: the selection stays ({sp!r})')
        g.key(1)                                    # Esc
        check(not boxed(), 'Esc closes it')
        alt_rclick(empty)
        g.click(*empty)
        g.pump(0.2)
        check(not boxed(), 'a click outside closes it')
        check(g.q('print(issel("Cube"))') == '1', 'and does nothing else (Cube still selected)')
        for text in ('make it bigger', 'stray: make it bigger', 'delete the light'):
            tp = ask(text)
            P.ended(f'"{text}"', tp)
            check(text in sent(), f'"{text}": the prompt was sent')
            if text.startswith('stray'):
                t = g.toast()
                check('also changed' in t and 'Camera and Light' in t, f'"{text}": the message names what else changed, joined by "and" ({t!r})')
            g.key(44, 4)                            # Ctrl+Z: the whole request
            g.pump(0.3)
        sp = sent()
        check('Change only the selection' in sp and 'one short sentence' in sp and '"name":"Cube"' in sp, 'the context: the selection as scene_summary lists it, what to keep to')
        tp = g.transcript()
        check('$ N about Cube' in tp, 'the transcript: a note of what it was about')
        check(g.q('print(exists("Light"), get("Cube", "sx"))') == '1 1', 'each request undone in one step')
        # Only the selection off: remembered, and not asked for
        alt_rclick(empty)
        g.click_widget('Only the selection')
        g.type('stray again')
        g.key(28)
        P.wait()
        check('Change only the selection' not in sent() and g.toast().startswith('AI: Done'), f'Only the selection off: nothing said of the light ({g.toast()!r})')
        pf = open(os.path.join(g.home, '.config', 'beemodel-zig', 'prefs')).read()
        check('ai_only_selection 0' in pf, 'the toggle is remembered (ai_only_selection 0)')
        g.key(44, 4)
        alt_rclick(empty)
        g.click_widget('Only the selection')
        g.key(1)
        # two selected, none, many
        g.q('add("sphere", "Ball", 3, 1, 0)\nselect("Cube", "Ball")')
        tp = ask('make them bigger')
        P.ended('two selected', tp)
        check('"name":"Cube"' in sent() and '"name":"Ball"' in sent(), 'two selected: each is in what was sent')
        g.q('select()')
        ask('what is here')
        check('Nothing is selected: the request is about the scene.' in sent(), 'nothing selected: about the scene')
        g.q('for i in 0..20 { add("cube", "Box" + str(i), i, 0, -4) }')
        g.tool('select', {'names': ['Box%d' % i for i in range(20)]})
        ask('what about these')
        check('... and 4 more selected objects' in sent() and 'Selected objects (20)' in sent(), f'20 selected: 16 listed and "... and 4 more" ({sent()[-120:]!r})')
        # history: Up
        g.q('select("Cube")')
        alt_rclick(empty)
        g.key(103)
        g.pump(0.1)
        g.key(28)
        P.wait()
        check(sent().startswith('what about these\n'), 'Up brings back the last prompt')
        # quick buttons
        alt_rclick(empty)
        g.click_widget('Bigger')
        P.wait()
        check(sent().startswith('Make it 50% bigger.'), 'Bigger sends at once')
        alt_rclick(empty)
        g.click_widget('Material...')
        g.pump(0.1)
        g.type('gold')
        g.key(28)
        P.wait()
        check(sent().startswith('Change the material to gold\n'), f'Material... starts the prompt, the rest typed ({sent()[:40]!r})')
        # edit mode: the selected elements, their centre, the mesh operators
        g.q('edit("Cube")\nvselect("Cube")\nfor i in 0..verts("Cube") { if vpos("Cube", i, "y") > 0 { vsel("Cube", i, 1) } }')
        tp = ask('extrude these')
        P.ended('edit mode', tp)
        check('vertices selected' in sent() and 'mesh.extrude' in sent(), 'edit mode: the selected elements and the mesh operators')
        g.q('edit()')
        # while it works: the status bar's chip; a click stops it
        alt_rclick(empty)
        g.type('a slow one')
        g.key(28)
        g.pump(0.6)
        w = g.widget('status.ai_working')
        check(bool(w) and not boxed(), 'the box closed; the status bar shows the request')
        if w:
            g.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        tp = P.wait(8)
        check('idle' in tp[0] and g.widget('status.ai_working') is None, 'clicking it stops the AI')
    finally:
        P.close()


def s_fuzz():
    print('-- the stream parsers fuzzed through the window: every request ends, the program runs on')
    P = Solo(prefs=or_prefs(steps=6), secret=KEY)
    g = P.p
    try:
        P.mode()
        pick_connection(g, 0)                       # (the prefs chose OpenRouter)
        n = max(10, NFUZZ // 6)
        bad = 0
        for seed in range(n):
            P.send('cfuzz %d please' % seed)
            tp = P.wait(30)
            if not (tp and 'idle' in tp[0]):
                bad += 1
                if bad <= 2:
                    print(f'     cfuzz {seed}: not idle:', repr(tp[:1]))
            if not g.alive():
                break
        check(bad == 0 and g.alive(), f'{n} random CLI streams (broken lines, odd bytes, huge lines, random pieces, random exits): each ended ({bad} did not)')
        pick_connection(g, 2)
        bad = 0
        for seed in range(max(6, NFUZZ // 15)):
            P.send('orfuzz %d please' % seed)
            tp = P.wait(30)
            if not (tp and 'idle' in tp[0]) or g.scene() is None:
                bad += 1
                if bad <= 2:
                    print(f'     orfuzz {seed}: not idle, or no scene:', repr(tp[:1]))
            if not g.alive():
                break
        check(bad == 0 and g.alive(), f'random OpenRouter replies (broken JSON, wrong types, tool calls of every shape): each ended, the scene reads back ({bad} did not)')
        g.click_widget('Copy')
        g.pump(0.3)
        clip = g.clipboard()
        check(len(clip) > 0 and 'orfuzz' in clip, f'after the fuzz: Copy gives the conversation ({len(clip)} bytes)')
        # MCP: build_world gives other agents the instructions
        for goal in ('a castle', None):
            args = {'name': 'build_world', 'arguments': {'goal': goal}} if goal else {'name': 'build_world'}
            rp = g.call('prompts/get', args)
            txt = (((rp or {}).get('result') or {}).get('messages') or [{}])[0].get('content', {}).get('text', '')
            check('scene_summary' in txt and (txt.endswith('What to build: a castle') if goal else txt.endswith('revert in one click. Answer briefly: what you built and what they could ask for next.')), f'MCP prompts/get build_world ({goal}): the instructions, the goal last')
    finally:
        P.close()


def headless(args, env=None, timeout=120):
    h = tempfile.mkdtemp(prefix='hl', dir=T)
    for d in ('.cache', '.config', '.local/share', '.local/state', 'run'):
        os.makedirs(os.path.join(h, d), exist_ok=True)
    b = make_bin(h)
    e = {'PATH': b + ':' + SYSPATH, 'HOME': h, 'XDG_CACHE_HOME': h + '/.cache', 'XDG_CONFIG_HOME': h + '/.config',
         'XDG_DATA_HOME': h + '/.local/share', 'XDG_STATE_HOME': h + '/.local/state', 'XDG_RUNTIME_DIR': h + '/run'}
    e.update(env or {})
    log = os.path.join(h, 'log.txt')
    p = subprocess.Popen(['taskset', '-c', str(CPU), BIN, '--shot', os.path.join(h, 'o.ppm'), '--size', '640x400', *args, '--dump-log', log],
                         env=e, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)  # (a pipe: the child's must be /dev/null)
    HELD.append(p)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return -9, [], err.decode('utf-8', 'replace'), h
    lines = open(log, encoding='utf-8', errors='replace').read().split('\n') if os.path.exists(log) else []
    return p.returncode, lines, err.decode('utf-8', 'replace'), h


def s_headless():
    print('-- the headless driver: no MCP server, the CLI fuzzed on the debug build, real curl, Stop, the files')
    rc, lines, err, h = headless(['--op', 'ai.send build a tower', '--op', 'ai.transcript'])
    check(rc == 0 and "$ E BeeModel's MCP server is off (Preferences > AI): Claude Code and Grok reach the " in lines,
          'no MCP server: Claude Code is not started, it says why')
    check(not os.path.exists(os.path.join(h, 'claude.runs.jsonl')), 'and nothing ran')
    rc, lines, err, h = headless(['--mcp-listen', '--op', 'ai.send build a tower', '--ai-wait', '20000', '--op', 'ai.transcript'])
    check(rc == 0 and '$ A Built a tower of 3 cubes.' in lines, f'headless: --mcp-listen and --ai-wait build the tower ({rc})')
    runs = [json.loads(l) for l in open(os.path.join(h, 'claude.runs.jsonl'))] if os.path.exists(os.path.join(h, 'claude.runs.jsonl')) else []
    check(runs and runs[0]['stdin_dev'] and runs[0]['stdout_is_stderr'], 'the child: stdin /dev/null (not ours, a pipe here), stdout and stderr one pipe')
    adir = os.path.join(h, '.cache', 'beemodel', 'ai')
    check(os.path.isdir(adir) and stat.S_IMODE(os.stat(adir).st_mode) == 0o700, 'the AI folder is ~/.cache/beemodel/ai, 0700')
    # the CLI fuzzed: many random streams, one process at a time, on the debug build
    n = NFUZZ
    per = 50
    crashed = 0
    ran = 0
    t0 = time.time()
    for base in range(0, n, per):
        a = ['--mcp-listen']
        for seed in range(base, min(n, base + per)):
            a += ['--op', 'ai.send cfuzz %d please' % (1000 + seed), '--ai-wait', '20000']
        a += ['--op', 'ai.transcript']
        rc, lines, err, h = headless(a, timeout=300)
        ran += sum(1 for _ in open(os.path.join(h, 'claude.runs.jsonl'))) if os.path.exists(os.path.join(h, 'claude.runs.jsonl')) else 0
        if rc != 0 or 'panic' in err or not any(l.startswith('$ ai: idle') for l in lines):
            crashed += 1
            if crashed == 1:
                print('     rc', rc, err[-800:])
    check(crashed == 0 and ran == n, f'{n} random CLI streams on the debug build: no panic, no hang, every request ended ({ran} ran, {time.time() - t0:.0f} s)')
    # OpenRouter fuzzed through the fake server, the key from OPENROUTER_API_KEY
    a = ['--mcp-listen', '--ai-pref', 'ai_connection 2', '--ai-pref', 'openrouter_url http://127.0.0.1:%d/h/api/v1' % PORT, '--ai-pref', 'openrouter_steps 5']
    for seed in range(max(20, NFUZZ // 5)):
        a += ['--op', 'ai.send orfuzz %d please' % (500 + seed), '--ai-wait', '20000']
    a += ['--op', 'ai.transcript']
    rc, lines, err, h = headless(a, env={'OPENROUTER_API_KEY': KEY}, timeout=600)
    nreq = len([x for x in SEEN if x['who'] == 'h'])
    check(rc == 0 and 'panic' not in err and any(l.startswith('$ ai: idle') for l in lines) and nreq >= 20, f'random OpenRouter replies on the debug build: no panic, every request ended ({rc}, {nreq} requests)')
    cr = [json.loads(l) for l in open(os.path.join(h, 'curl.runs.jsonl'))] if os.path.exists(os.path.join(h, 'curl.runs.jsonl')) else []
    check(cr and all(KEY not in x for r in cr for x in r['args']) and all(r.get('hdr_mode') == 0o600 for r in cr),
          f'OPENROUTER_API_KEY: in the 0600 header file, never on the command line ({len(cr)} requests)')
    # real curl, through the guard (127.0.0.1 only)
    real = shutil.which('curl', path=SYSPATH)
    if real:
        a = ['--mcp-listen', '--ai-pref', 'ai_connection 2', '--ai-pref', 'openrouter_url http://127.0.0.1:%d/h/api/v1' % PORT,
             '--op', 'ai.send make a ring', '--ai-wait', '30000', '--op', 'ai.transcript']
        rc, lines, err, h = headless(a, env={'OPENROUTER_API_KEY': KEY, 'FAKE_CURL_REAL': real})
        check('$ A Made a ring of 4 spheres.' in lines, f'real curl ({real}) against the local server: the tool loop to its answer')
    else:
        print('  (no curl on this machine: the real curl is not tried)')
    # a test of each connection (ai.test), from the console
    a = ['--ai-pref', 'openrouter_url http://127.0.0.1:%d/h/api/v1' % PORT]
    for k in ('0', '1', '2', '7'):
        a += ['--op', 'ai.test ' + k, '--ai-wait', '10000']
    a += ['--op', 'ai.transcript']
    rc, lines, err, h = headless(a, env={'OPENROUTER_API_KEY': KEY})
    check('$ N Claude Code: 9.9.9 (Claude Code)' in lines and '$ N Grok: grok 9.9.9' in lines and '$ N OpenRouter: the key works' in lines
          and lines.count('$ N Claude Code: 9.9.9 (Claude Code)') == 2, 'ai.test 0, 1, 2 (and 7: Claude Code, the fallback)')
    check('  Claude Code: 9.9.9 (Claude Code)' in lines and '  OpenRouter: the key works' in lines, 'and the console says so')


def pick_connection(g, row):
    """The AI Assistant's connection list: opened, the row clicked."""
    names = ['Claude Code', 'Grok', 'OpenRouter', 'Ollama']
    w = None
    for x in g.widgets():
        if x['kind'] in ('enum', 'button') and x['name'] in names:
            w = x
    if not w:
        return
    g.click(w['x'] + 20, w['y'] + w['h'] // 2)
    g.pump(0.2)
    for x in g.widgets():
        if x['name'] == names[row] and x['kind'] not in ('enum', 'button'):
            g.click(x['x'] + 10, x['y'] + x['h'] // 2)
            break
    g.pump(0.2)


def main():
    t0 = time.time()
    try:
        if section('cli'):
            s_cli()
        if section('or'):
            s_or()
        if section('prefs'):
            s_prefs()
        if section('ask'):
            s_ask()
        if section('fuzz'):
            s_fuzz()
        if section('headless'):
            s_headless()
    finally:
        for p in HELD:
            try:
                p.kill()
            except Exception:
                pass
        SRV.shutdown()
        shutil.rmtree(T, ignore_errors=True)
    for what, a in PERF:
        print(f'  perf {what}: {a:.3f}')
    print(f'ai: {time.time() - t0:.0f} s')
    print(f'ai: fails {len(FAILS)}')
    for f in FAILS:
        print('  FAILED:', f)
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
