#!/usr/bin/env python3
"""Versioned scenes (vc.zig, versions.zig): scripts through BeeModel, each
with a temp HOME and all five XDG folders of its own.

  * flow: a walkthrough (commit, branch, switch, diff, merge, conflicts,
    resolve) - the printed values it must give;
  * store: the repository it writes: every blob and commit named by the hash
    of its bytes, each commit's lines in order, the history whole (parents,
    merges with two), the manifests in their bounds, the refs naming commits;
  * cross: a repository opened again in a fresh run, worked on, read back;
  * console: the operators' console lines through MCP replies, for every
    operator and every refusal (no file, no commit, no such branch, changes,
    conflicts, up to date): an answer to each, the program still there;
  * undo: undo and redo around commit, switch, merge, resolve, abort;
  * damaged: truncated, garbage and oversized refs, commits, manifests, mesh
    blobs and scene blobs: no crash, no hang, an answer to the end;
  * random: random histories run cleanly, every step printed, twice the same;
  * window: the diff's ghosts (overlay and side), its list, the merge panel's
    buttons, and the Versions editor, in the fake compositor.

    python3 tests/vc.py BIN [runs=1]

BEE_CPU (default 8) pins the window programs; VC_ONLY=flow,store,... runs some
sections; VC_SHOTS=dir keeps the screenshots.
"""
import json, os, random, re, shutil, socket, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = int(os.environ.get('BEE_CPU', '8'))
ONLY = [x for x in os.environ.get('VC_ONLY', '').split(',') if x]
SHOTS = os.environ.get('VC_SHOTS')
FAILS = []
T = tempfile.mkdtemp(prefix='bvc-', dir='/tmp')   # (short: unix socket paths)
os.environ['TMPDIR'] = T
tempfile.tempdir = T
PROGS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def section(name):
    return not ONLY or name in ONLY


# ---- the hash, the store ----------------------------------------------------------

M64 = (1 << 64) - 1


def vch(d):
    """vc_hash: FNV-like over 8-byte words (rotated 23), then the bytes, a finalizer."""
    h, p, i = 0xcbf29ce484222325, 0x100000001b3, 0
    while len(d) - i >= 8:
        h ^= struct.unpack_from('<Q', d, i)[0]
        h = (h * p) & M64
        h = ((h << 23) | (h >> 41)) & M64
        i += 8
    while i < len(d):
        h ^= d[i]
        h = (h * p) & M64
        i += 1
    h ^= h >> 33
    h = (h * 0xff51afd7ed558ccd) & M64
    h ^= h >> 33
    return h or 1


def store_named_ok(vc):
    """Every blob and commit's name is the hash of its bytes (count, bad)."""
    n, bad = 0, []
    for sub in ('blobs', 'commits'):
        d = os.path.join(vc, sub)
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            n += 1
            if '%016x' % vch(open(os.path.join(d, f), 'rb').read()) != f:
                bad.append(f)
    return n, bad


def mf_fits(d):
    """A manifest's counts and entries inside its bytes (16 header, 128 an
    object, 16 a chunk)."""
    if len(d) < 16:
        return False
    no, nc = struct.unpack_from('<II', d, 4)
    return 16 + no * 128 + nc * 16 <= len(d)


def commits(vc):
    """message -> the commit's fields (scene, manifest, parents, time)."""
    out = {}
    d = os.path.join(vc, 'commits')
    for f in os.listdir(d) if os.path.isdir(d) else []:
        t = open(os.path.join(d, f), 'rb').read().decode('latin-1')
        c = {'id': f, 'parent': [], 'keys': []}
        for line in t.split('\n'):
            if not line:
                continue
            k, _, v = line.partition(' ')
            c['keys'].append(k)
            if k == 'parent':
                c['parent'].append(v)
            else:
                c[k] = v
        out.setdefault(c.get('message', ''), []).append(c)
    return out


# ---- running BeeModel ---------------------------------------------------------------

def run(binary, home, args, timeout=300):
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home)
    for var, sub in (('XDG_CACHE_HOME', 'c'), ('XDG_CONFIG_HOME', 'cf'), ('XDG_DATA_HOME', 'd'),
                     ('XDG_STATE_HOME', 's'), ('XDG_RUNTIME_DIR', 'r')):
        os.makedirs(os.path.join(home, sub), mode=0o700, exist_ok=True)
        env[var] = os.path.join(home, sub)
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DISPLAY', None)
    try:
        r = subprocess.run([binary, *args], env=env, cwd=home, capture_output=True, text=True, timeout=timeout, errors='replace')
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return None, 'timeout', -1


def script(code, timeout=300):
    """A script through BeeModel in a fresh home: ((stdout, stderr, rc), home)."""
    h = tempfile.mkdtemp(prefix='p')
    s = os.path.join(h, 'x.bees')
    with open(s, 'w') as f:
        f.write(code)
    return run(BIN, h, ['--run', s], timeout), h


def clean(r):
    """Exit 0, an answer, no panic or safety check."""
    out, err, rc = r
    e = (err or '') + (out or '')
    return rc == 0 and out is not None and 'panic' not in e and 'reached unreachable' not in e and 'integer overflow' not in e


def lines(out):
    d = {}
    for line in (out or '').splitlines():
        w = line.split(None, 1)
        if w:
            d.setdefault(w[0], []).append(w[1] if len(w) > 1 else '')
    return d


# ---- BeeModel in its window (the fake compositor), MCP on it --------------------

class Prog:
    """BeeModel in the fake compositor, an MCP client on its socket."""

    def __init__(self, size=(1280, 800), binary=None):
        self.home = tempfile.mkdtemp(prefix='h', dir=T)
        os.makedirs(os.path.join(self.home, 'BeeModel'))
        env = {'BEEMODEL_GPU_VIEW': 'off', 'BEEMODEL_WELCOME': '0', 'BEEMODEL_AGENT_PERMISSION': 'files'}
        for var, sub in (('XDG_CONFIG_HOME', 'cf'), ('XDG_DATA_HOME', 'd'), ('XDG_STATE_HOME', 's')):
            os.makedirs(os.path.join(self.home, sub), exist_ok=True)
            env[var] = os.path.join(self.home, sub)
        from wl_fake import Fake
        env.update(HOME=self.home, XDG_RUNTIME_DIR=self.home, XDG_CACHE_HOME=os.path.join(self.home, 'cache'))
        self.f = Fake(binary or BIN, size=size, env=env)
        PROGS.append(self)
        self.f.until(lambda: self.f.frames > 0, 10)
        self.pid = self.f.proc.pid
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
        for _ in range(50):
            try:
                s.connect(os.path.join(self.home, 'beemodel.sock'))
                break
            except OSError:
                self.pump(0.1)
        s.setblocking(False)
        return s

    def reply(self, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            if b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                return line
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

    def tool(self, name, args=None, timeout=8.0):
        """A tool's text reply (and isError), or (None, None)."""
        self.seq += 1
        rid = 'q%d' % self.seq
        m = {'jsonrpc': '2.0', 'id': rid, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}
        try:
            self.s.sendall((json.dumps(m, separators=(',', ':')) + '\n').encode())
        except OSError:
            return None, None
        t0 = time.time()
        while time.time() - t0 < timeout:
            r = self.reply(timeout - (time.time() - t0))
            if r is None:
                return None, None
            try:
                j = json.loads(r)
            except ValueError:
                continue
            if j.get('id') != rid:
                continue
            try:
                return j['result']['content'][0]['text'], j['result']['isError']
            except (KeyError, IndexError, TypeError):
                return None, None
        return None, None

    def op(self, op_id, arg=None):
        """An operator through MCP: its console lines (the reply's text)."""
        a = {} if arg is None else {'arg': arg}
        t, _ = self.tool('op_' + op_id.replace('.', '_'), a)
        return (t or '').replace(self.home, '$HOME')

    def ev(self, code):
        t, _ = self.tool('script_eval', {'code': code})
        return (t or '').strip()

    def image(self):
        from PIL import Image
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def click(self, x, y):
        self.f.enter(x, y)
        self.f.motion(x, y)
        self.f.pump(0.05)
        self.f.button(0x110, True)
        self.f.pump(0.05)
        self.f.button(0x110, False)
        self.pump(0.4)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        try:
            self.f.close()
        except Exception:
            pass
        try:
            self.f.proc.kill()
        except Exception:
            pass


def kill_all():
    for p in PROGS:
        try:
            p.f.proc.kill()
            p.f.proc.wait(5)
        except Exception:
            pass


import atexit  # noqa: E402
atexit.register(kill_all)
atexit.register(shutil.rmtree, T, True)


# ---- flow: the walkthrough -------------------------------------------------------------

FLOW = '''
add("sphere", "Ball", 2, 1, 0)
add("cube", "Old", 0, 0.5, -4)
material("Gold")
assign("Ball", "Gold")
print("none", vcinfo(0), vcinfo(1), vctext(0), vctext(3))
op("file.save", "~/BeeModel/v.bee")
print("nocommit", vcinfo(0), vcinfo(1), vcinfo(2), vctext(0), vctext(3), vctext(1, 0), vctext(2, 0))
op("vc.commit", "first")
op("vc.commit", "again")
print("first", vcinfo(0), vcinfo(1), vcinfo(2), vctext(0), vctext(3))
op("vc.branch", "idea")
op("vc.switch", "idea")
move("Ball", 5, 1, 0)
add("cube", "Box", -3, 0.5, 0)
delete("Old")
vmove("Cube", 0, 2, 2, 2)
material("Red")
matset("Red", "base", 0.9, 0.1, 0.1)
assign("Box", "Red")
op("vc.commit", "on idea")
print("idea", vctext(0), vcinfo(1), vcinfo(2))
op("vc.switch", "main")
print("main", get("Ball", "x"), count(), vpos("Cube", 0, 0))
op("vc.diff", "idea")
print("diff", vcinfo(3), vcinfo(4), vcinfo(5), vcinfo(6))
print("rows", vctext(1, 0))
print("rows", vctext(1, 1))
print("rows", vctext(1, 2))
print("rows", vctext(1, 3))
print("rowsout", vctext(1, 4), vctext(1, -1), vctext(9), vcinfo(10), vcinfo(-1))
op("vc.diff", "idea side")
print("side", vcinfo(3))
op("vc.diff", "off")
print("off", vcinfo(3))
set("Cube", "y", 3)
op("vc.switch", "idea")
print("refused", vctext(0), get("Cube", "y"))
op("vc.commit", "on main")
op("vc.merge", "idea")
print("merged", get("Ball", "x"), get("Cube", "y"), vpos("Cube", 0, 0), count(), matof("Box"), round(matget("Red", "base", 0) * 10), vcinfo(7), vcinfo(9))
print("old", count(), exists("Old"))
op("vc.commit", "merge idea")
print("after", vcinfo(1), vcinfo(9), vctext(3))
op("vc.merge", "idea")
print("uptodate", vcinfo(9))
op("vc.switch", "idea")
set("Cube", "y", 9)
set("Ball", "color", 255)
op("vc.commit", "idea moves the cube")
op("vc.switch", "main")
set("Cube", "y", 7)
set("Ball", "hidden", 1)
op("vc.commit", "main moves it too")
op("vc.merge", "idea")
print("conflict", vcinfo(7), vcinfo(8), get("Cube", "y"), get("Ball", "color"), get("Ball", "hidden"))
print("conflictrow", vctext(2, 0))
print("conflictout", vctext(2, 1), vctext(2, -1))
op("vc.commit", "too early")
print("early", vcinfo(9))
op("vc.resolve", "2 theirs")
op("vc.resolve", "0 theirs")
op("vc.resolve", "1 sideways")
op("vc.resolve", "x theirs")
print("notyet", vcinfo(8))
op("vc.resolve", "1 theirs")
print("resolved", vcinfo(8), get("Cube", "y"), vctext(2, 0))
op("vc.resolve", "all ours")
print("allours", vcinfo(8), get("Cube", "y"), vctext(2, 0))
op("vc.resolve", "1.9 theirs")
print("float", vcinfo(8), get("Cube", "y"), vctext(2, 0))
op("vc.commit")
print("final", vcinfo(1), vcinfo(9), vctext(3), vcinfo(7))
op("vc.switch", "idea")
rename("Ball", "Sphere")
add("cube", "Fresh", 1, 1, 1)
op("vc.commit", "idea renames")
op("vc.switch", "main")
delete("Ball")
op("vc.commit", "main deletes the ball")
op("vc.merge", "idea")
print("delconf", vcinfo(7), vctext(2, 0), count(), exists("Fresh"), exists("Sphere"))
op("vc.resolve", "1 theirs")
print("back", count(), exists("Sphere"), vcinfo(8))
op("vc.resolve", "1 ours")
print("gone", count(), exists("Sphere"), vcinfo(8))
op("vc.abort")
print("aborted", vcinfo(9), vcinfo(7), count(), exists("Fresh"))
op("vc.merge", "nope")
op("vc.switch", "nope")
op("vc.branch", "")
op("vc.branch", "abcdefghijklmnopqrstuvwxyz0123456789")
op("vc.branch", "abcdefghijklmnopqrstuvwxyz0123456789")
print("long", vcinfo(2), vctext(0))
op("vc.switch", "abcdefghijklmnopqrstuvwxyz0123456789")
print("longsw", vctext(0))
op("vc.switch", "abcdefghijklmnopqrstuvwxyz01234")
print("longsw2", vctext(0), vcinfo(1))
'''


FLOW_COMMITS = ['', 'first', 'idea moves the cube', 'idea renames', 'main deletes the ball', 'main moves it too',
                'merge idea', 'on idea', 'on main']   # (what FLOW commits: "again" and "too early" make none)


def s_flow():
    print('-- flow: commit, branch, switch, diff, merge, conflicts, resolve')
    for run_no in range(RUNS):
        p, home = script(FLOW)
        pl = (p[0] or '').splitlines()
        check(clean(p) and len(pl) > 30, f'run {run_no + 1}: the script ran to the end ({len(pl)} lines, rc {p[2]}; stderr: {(p[1] or "")[-300:]})')
        g = lambda k: (lines(p[0]).get(k) or [''])[0].split()
        check(g('first') == ['1', '1', '1', 'main', 'first'], f'a commit; nothing changed: no second one ({g("first")})')
        check(g('diff') == ['4', '1', '1', '2'], f'vc.diff idea: what differs ({g("diff")})')
        check(g('merged')[:4] == ['5', '3', '2', '5'] and g('merged')[4:5] == ['Red'], f'vc.merge: theirs in, ours kept ({g("merged")})')
        check(g('resolved')[:2] == ['0', '9'], f'vc.resolve 1 theirs ({g("resolved")})')
        check(g('long')[:1] == ['4'], f'a name longer than 31: cut, and made again each time ({g("long")})')
        check(g('allours')[-1:] == ['(ours)'] and g('resolved')[-1:] == ['(theirs)'], f'a settled conflict says which side ({g("allours")})')
        check(g('longsw') == ['abcdefghijklmnopqrstuvwxyz01234'], f'a switch to the long name: the cut branch ({g("longsw")})')
        check(g('conflict') == ['1', '1', '7', '255', '1'],
              f'each side moved the cube: one conflict, ours shown till settled; their colour and our hidden flag in ({g("conflict")})')
        check(g('delconf')[:1] == ['1'] and g('back')[1:2] == ['1'] and g('gone')[1:2] == ['0'],
              f'deleted here, renamed there: a conflict; theirs brings it back, ours deletes it ({g("delconf")[:1]}, {g("back")}, {g("gone")})')
        if run_no == 0:
            s_store(home)
        shutil.rmtree(home, True)


def s_store(home):
    print('-- store: what BeeModel wrote beside the scene')
    vc = os.path.join(home, 'BeeModel', 'v.bee.vc')
    n, bad = store_named_ok(vc)
    check(n > 20 and not bad, f'every blob and commit is named by the hash of its bytes ({n} files, {len(bad)} not)')
    cs = commits(vc)
    check(sorted(cs) == FLOW_COMMITS and all(len(v) == 1 for v in cs.values()),
          f'one commit for each the script made ({sorted(cs)})')
    order = lambda k: k[:2] == ['scene', 'manifest'] and k[-2:] == ['time', 'message'] and all(x == 'parent' for x in k[2:-2])
    check(all(order(c['keys']) for l in cs.values() for c in l), 'each commit\'s lines in order (scene, manifest, parent(s), time, message)')
    ids = {c['id'] for l in cs.values() for c in l}
    allc = [c for l in cs.values() for c in l]
    check(all(p in ids for c in allc for p in c['parent']), 'every parent is a commit in the store')
    roots = [c for c in allc if not c['parent']]
    two = sorted(m for m, l in cs.items() for c in l if len(c['parent']) == 2)
    check(len(roots) == 1 and two == ['', 'merge idea'], f'one root; the two merges have two parents ({len(roots)}, {two})')
    blobs = os.path.join(vc, 'blobs')
    have = lambda f: os.path.isfile(os.path.join(blobs, f))
    check(all(have(c.get('scene', '')) and have(c.get('manifest', '')) for c in allc), 'every commit\'s scene and manifest blob is there')
    mfs = [open(os.path.join(blobs, c['manifest']), 'rb').read() for c in allc if have(c.get('manifest', ''))]
    check(len(mfs) == len(allc) and all(mf_fits(m) for m in mfs), f'the manifests\' counts inside their bytes ({len(mfs)})')
    meshes = [f for f in os.listdir(blobs) if (lambda b: len(b) >= 20 and b[:4] == b'\0\0\0\0' and struct.unpack_from('<I', b, 4)[0] > 0)(open(os.path.join(blobs, f), 'rb').read())]
    check(len(meshes) >= 3, f'the mesh blobs ({len(meshes)})')
    refs = open(os.path.join(vc, 'refs')).read().splitlines()
    heads = [r.split(' ', 1)[1] for r in refs if r.startswith('head ')]
    br = {r.split()[1]: r.split()[2] for r in refs if r.startswith('branch ') and len(r.split()) == 3}
    check(len(heads) == 1 and heads[0] in br and set(br) >= {'main', 'idea'} and all(v in ids for v in br.values()),
          f'the refs: a head on a branch, every branch on a commit ({refs})')


# ---- cross: a repository opened again ---------------------------------------------------

MAKE = '''
add("sphere", "Ball", 2, 1, 0)
add("cube", "Old", 0, 0.5, -4)
material("Gold")
assign("Ball", "Gold")
op("file.save", "~/BeeModel/v.bee")
op("vc.commit", "one")
op("vc.branch", "b")
op("vc.switch", "b")
move("Ball", 5, 1, 0)
vmove("Cube", 0, 1, 1, 1)
op("vc.commit", "two")
op("vc.switch", "main")
set("Old", "y", 3)
op("vc.commit", "three")
op("file.save", "~/BeeModel/v.bee")
print("made", vcinfo(1), vcinfo(2))
'''

USE = '''
op("file.open", "~/BeeModel/v.bee")
print("open", vcinfo(0), vcinfo(1), vcinfo(2), vctext(0), vctext(3), count())
op("vc.commit", "again")
print("same", vcinfo(1), vctext(3))
op("vc.diff")
print("diffhead", vcinfo(3))
op("vc.diff", "b")
print("diffb", vcinfo(3), vctext(1, 0), "|", vctext(1, 1), "|", vctext(1, 2))
op("vc.switch", "b")
print("b", vctext(0), vcinfo(1), get("Ball", "x"), get("Old", "y"), vpos("Cube", 0, 0), count())
op("vc.switch", "main")
op("vc.merge", "b")
print("merge", vcinfo(9), vcinfo(7), get("Ball", "x"), get("Old", "y"), vpos("Cube", 0, 0))
op("vc.commit", "merged by the other")
set("Ball", "z", 3)
op("vc.commit", "cross")
print("cross", vcinfo(1), vctext(3))
op("file.save", "~/BeeModel/v.bee")
'''

BACK = '''
op("file.open", "~/BeeModel/v.bee")
print("back", vcinfo(1), vctext(3), get("Ball", "z"), get("Ball", "x"))
op("vc.commit", "nothing")
print("backsame", vcinfo(1))
op("vc.switch", "b")
print("backb", get("Ball", "x"), vcinfo(1))
'''


def s_cross():
    print('-- cross: a repository opened again in a fresh run, worked on, read back')
    h = tempfile.mkdtemp(prefix='p')
    rs = [run(BIN, h, ['--eval', code]) for code in (MAKE, USE, BACK)]
    check(all(clean(r) for r in rs), f'the three runs ended cleanly (rc {[r[2] for r in rs]})')
    mk, use, back = (lines(r[0]) for r in rs)
    g = lambda d, k: (d.get(k) or [''])[0]
    check(g(mk, 'made') == '2 2', f'the history made ({g(mk, "made")})')
    check(g(use, 'open').startswith('1 2 2 main three'), f'opened again: the file\'s repository, on main at "three" ({g(use, "open")})')
    check(g(use, 'same') == '2 three', f'nothing changed since its last commit: no new one ({g(use, "same")})')
    check(g(use, 'diffhead') == '0', f'vc.diff with the head: nothing ({g(use, "diffhead")})')
    b = g(use, 'b').split()
    check(b[:1] == ['b'] and b[2:4] == ['5', '0.5'], f'vc.switch b: its Ball moved, Old where it was ({b})')
    m = g(use, 'merge').split()
    check(m[:4] == ['1', '0', '5', '3'], f'vc.merge b: merging, no conflict, each side\'s move in ({m})')
    check(g(use, 'cross').endswith(' cross'), f'two more commits on it ({g(use, "cross")})')
    bk = g(back, 'back').split()
    check(bk[1:] == ['cross', '3', '5'], f'read back in a third run: the last commit and the scene ({bk})')
    check(g(back, 'backsame') == bk[:1][0] if bk else False, f'and nothing changed: no new commit ({g(back, "backsame")})')
    check(g(back, 'backb').split()[:1] == ['5'], f'branch b as it was ({g(back, "backb")})')
    n, bad = store_named_ok(os.path.join(h, 'BeeModel', 'v.bee.vc'))
    check(n > 10 and not bad, f'every file still named by its hash ({n})')
    shutil.rmtree(h, True)


# ---- console: the operators' words, through MCP -----------------------------------------

def s_console():
    print('-- console: every operator\'s console lines and refusals (MCP replies)')
    p = Prog()
    said = lambda r: r.strip() != ''   # (an MCP reply came: the operator's lines, maybe none past its title)
    try:
        steps = [('vc.commit', 'x'), ('vc.log', ''), ('vc.branch', 'b'), ('vc.switch', 'b'), ('vc.diff', ''),
                 ('vc.merge', 'b'), ('vc.resolve', '1 ours'), ('vc.abort', '')]
        for op_, a in steps:
            rp = p.op(op_, a)
            check(said(rp), f'no file: {op_} {a} -> {rp.splitlines()[1:]!r}')
        r = p.ev('print(vcinfo(0), vcinfo(1), vcinfo(2), count())')
        check(r.split()[:3] == ['0', '0', '0'], f'no file: no repository made ({r})')
        p.ev('add("sphere", "Ball", 2, 1, 0)\nadd("cube", "Box", -2, 0.5, 0)')
        p.op('file.save', p.home + '/BeeModel/w.bee')
        seq = [('vc.log', ''), ('vc.branch', 'early'), ('vc.diff', ''), ('vc.merge', 'early'), ('vc.switch', 'early'),
               ('vc.commit', 'first'), ('vc.commit', 'again'), ('vc.branch', ''), ('vc.branch', 'b'), ('vc.branch', 'b'),
               ('vc.switch', ''), ('vc.switch', 'nope'), ('vc.switch', 'b'), ('vc.diff', 'zz'), ('vc.diff', 'main'),
               ('vc.merge', 'main'), ('vc.merge', ''), ('vc.merge', 'nope'), ('vc.resolve', '1 ours'), ('vc.resolve', ''),
               ('vc.abort', ''), ('@', 'move("Ball", 5, 1, 0)\nset("Box", "hidden", 1)\nvmove("Cube", 0, 1, 1, 1)'),
               ('vc.switch', 'main'), ('vc.diff', 'main'), ('vc.diff', 'main side'), ('vc.diff', 'b overlay'),
               ('vc.diff', 'off'), ('vc.commit', 'b moves the ball'), ('vc.switch', 'main'),
               ('@', 'set("Ball", "y", 4)\nset("Box", "color", 65280)\ndelete("Cube")'), ('vc.commit', 'main lifts the ball'),
               ('vc.merge', 'b'), ('vc.commit', 'too early'), ('vc.switch', 'b'), ('vc.resolve', '7 ours'),
               ('vc.resolve', '1 theirs'), ('vc.resolve', 'all ours'), ('vc.commit', ''), ('vc.log', ''),
               ('vc.merge', 'b'), ('vc.switch', 'b force'), ('vc.diff', 'main side'), ('vc.log', '')]
        logs = []
        for op_, a in seq:
            if op_ == '@':
                p.ev(a)
                continue
            rp = p.op(op_, a)
            if op_ == 'vc.log':
                logs.append(rp)
                continue
            check(said(rp), f'{op_} {a} -> {rp.splitlines()[1:]!r}')
        n = [len(x.splitlines()) for x in logs]
        check(len(logs) == 3 and all(said(x) for x in logs) and n[0] < n[1], f'vc.log: an answer each time, more rows after the commits ({n})')
        sp = p.ev('print(vcinfo(1), vcinfo(2), vctext(0), count(), get("Ball", "x"), get("Ball", "y"))')
        check(p.alive() and sp.split()[2:3] == ['b'], f'still there at the end, on b ({sp})')
    finally:
        p.close()


# ---- undo ----------------------------------------------------------------------------------

def s_undo():
    print('-- undo: around commit, switch, merge, resolve, abort')
    p = Prog()
    X = 'print(get("Ball", "x"), get("Ball", "y"), count(), vctext(0), vcinfo(9), vcinfo(8))'
    try:
        p.ev('add("sphere", "Ball", 2, 1, 0)')
        p.op('file.save', p.home + '/BeeModel/w.bee')
        p.op('vc.commit', 'first')
        p.op('vc.branch', 'b')
        p.op('vc.switch', 'b')
        p.ev('move("Ball", 5, 1, 0)\nadd("cube", "New", 0, 3, 0)')
        p.op('vc.commit', 'b moves')
        p.ev('move("Ball", 6, 1, 0)')
        # a commit changes nothing: undo takes back the edit before it
        p.op('vc.commit', 'b again')
        p.op('edit.undo')
        r = p.ev(X)
        p.op('edit.redo')
        check(r == '5 1 5 b 0 0', f'a commit is no step: undo takes back the edit before it ({r})')
        p.op('vc.switch', 'main force')
        r = p.ev(X)
        check(r == '2 1 4 main 0 0', f'vc.switch main force ({r})')
        p.op('edit.undo')
        r = p.ev(X)
        check(r == '6 1 5 main 0 0', f'undo after the switch: the scene before it, whole ({r})')
        p.op('edit.redo')
        r = p.ev(X)
        check(r == '2 1 4 main 0 0', f'redo: the switched scene again ({r})')
        # a merge that brings their changes and a conflict
        p.ev('set("Ball", "y", 4)')
        p.op('vc.commit', 'main lifts')
        p.op('vc.merge', 'b')
        r = p.ev(X)
        check(r == '2 4 5 main 1 1', f'vc.merge b: their new object in, the conflict open ({r})')
        p.op('edit.undo')
        r = p.ev(X)
        check(r == '2 4 4 main 1 1', f'undo after the merge: the scene before it (one step; the merge stays open) ({r})')
        p.op('edit.redo')
        r = p.ev(X)
        check(r == '2 4 5 main 1 1', f'redo: merged again ({r})')
        p.op('vc.resolve', '1 theirs')
        r = p.ev(X)
        check(r == '6 1 5 main 1 0', f'vc.resolve 1 theirs ({r})')
        p.op('edit.undo')
        r = p.ev(X)
        check(r == '2 4 5 main 1 0', f'undo after resolve: our value back, one step ({r})')
        p.op('edit.redo')
        p.op('vc.abort')
        r = p.ev(X)
        check(r == '2 4 4 main 0 0', f'vc.abort: the branch\'s last commit ({r})')
        p.op('edit.undo')
        r = p.ev(X)
        check(r == '6 1 5 main 0 0', f'undo after abort: the merged scene back as it was ({r})')
    finally:
        p.close()


# ---- damaged repositories ---------------------------------------------------------------

PROBE = '''
op("file.open", "~/BeeModel/v.bee")
print("a", vcinfo(0), vcinfo(1), vcinfo(2), vctext(0), vctext(3))
op("vc.diff", "b")
print("d", vcinfo(3), vctext(1, 0))
op("vc.diff", "b side")
op("vc.switch", "b force")
print("s", vctext(0), count())
op("vc.switch", "main force")
print("s2", vctext(0), count())
op("vc.merge", "b")
print("m", vcinfo(9), vcinfo(7), count())
op("vc.resolve", "all theirs")
op("vc.abort")
set("Ball", "z", 7)
op("vc.commit", "after")
print("c", vcinfo(1), vcinfo(2), vctext(3))
'''


def damage_cases(vc):
    """(name, fn(vc dir)) - each damages a copy of the repository."""
    rnd = random.Random(1234)
    cm = commits(vc)
    def blob(kind):
        # a blob of the head commit: its scene, its manifest; a mesh blob
        c = cm['three'][0]
        if kind == 'scene':
            return c['scene']
        if kind == 'manifest':
            return cm['two'][0]['manifest']   # (b's: the diff and the merge read it)
        return [f for f in sorted(os.listdir(os.path.join(vc, 'blobs')))
                if open(os.path.join(vc, 'blobs', f), 'rb').read(4) == b'\0\0\0\0']
    def wr(rel, data):
        with open(os.path.join(vc, rel), 'wb') as f:
            f.write(data)
    def rd(rel):
        return open(os.path.join(vc, rel), 'rb').read()
    def head_commit():
        return 'commits/' + cm['three'][0]['id']
    out = []
    refs = rd('refs')
    out += [('refs empty', lambda d: wr('refs', b'')),
            ('refs garbage', lambda d: wr('refs', bytes(rnd.randrange(256) for _ in range(300)))),
            ('refs cut mid-line', lambda d: wr('refs', refs[:len(refs) // 2])),
            ('refs without its last newline', lambda d: wr('refs', refs.rstrip(b'\n'))),
            ('refs 40 branches', lambda d: wr('refs', refs + b''.join(b'branch x%d 0123456789abcdef\n' % k for k in range(40)))),
            ('refs a head with no branch', lambda d: wr('refs', b'head ghost\n' + refs)),
            ('refs bad ids', lambda d: wr('refs', re.sub(rb'branch b [0-9a-f]+', b'branch b zz12', refs))),
            ('refs a merge of nothing', lambda d: wr('refs', refs + b'merge 0000000000000bad\n')),
            ('refs long lines', lambda d: wr('refs', b'head ' + b'x' * 5000 + b'\n' + refs)),
            ('refs 1 MiB', lambda d: wr('refs', refs + b'junk ' * 200000))]
    hc = head_commit()
    out += [('head commit truncated', lambda d: wr(hc, rd(hc)[:30])),
            ('head commit garbage', lambda d: wr(hc, bytes(rnd.randrange(1, 256) for _ in range(200)))),
            ('head commit empty', lambda d: wr(hc, b'')),
            ('head commit gone', lambda d: os.remove(os.path.join(d, hc))),
            ('head commit its own parent', lambda d: wr(hc, rd(hc).replace(b'time', b'parent ' + hc[8:].encode() + b'\ntime'))),
            ('head commit no newline at the end', lambda d: wr(hc, rd(hc).rstrip(b'\n'))),
            ('head commit a 4096-byte message', lambda d: wr(hc, rd(hc) + b'message ' + b'm' * 4096 + b'\n'))]
    def each(fs, g):
        return lambda d: [g(d, f) for f in fs]
    for kind in ('manifest', 'scene', 'mesh'):
        fs = ['blobs/' + x for x in (blob(kind) if kind == 'mesh' else [blob(kind)])]
        out += [(f'{kind} truncated', each(fs, lambda d, f: wr(f, rd(f)[:len(rd(f)) // 2]))),
                (f'{kind} 10 bytes', each(fs, lambda d, f: wr(f, rd(f)[:10]))),
                (f'{kind} garbage', each(fs, lambda d, f: wr(f, bytes(rnd.randrange(256) for _ in range(len(rd(f))))))),
                (f'{kind} gone', each(fs, lambda d, f: os.remove(os.path.join(d, f))))]
    mf = 'blobs/' + blob('manifest')
    out += [('manifest counts past its end', lambda d: wr(mf, rd(mf)[:4] + struct.pack('<II', 5000, 100) + rd(mf)[12:])),
            ('manifest 4096 objects claimed', lambda d: wr(mf, rd(mf)[:4] + struct.pack('<I', 4096) + rd(mf)[8:])),
            ('manifest bigger than any', lambda d: wr(mf, rd(mf) + bytes(600000)))]
    mbs = ['blobs/' + x for x in blob('mesh')]
    nv = lambda f: struct.unpack_from('<I', rd(f), 4)[0]
    out += [('mesh loops past its vertices', each(mbs, lambda d, f: wr(f, rd(f)[:-8] + struct.pack('<II', 999999, 7)))),
            ('mesh counts huge', each(mbs, lambda d, f: wr(f, rd(f)[:4] + struct.pack('<III', 0x7fffffff, 0x7fffffff, 0x7fffffff) + rd(f)[16:]))),
            ('mesh offsets falling', each(mbs, lambda d, f: wr(f, rd(f)[:24 + 12 * nv(f)] + struct.pack('<I', 0xffffff) + rd(f)[28 + 12 * nv(f):])))]
    out += [('blobs folder gone', lambda d: shutil.rmtree(os.path.join(d, 'blobs'))),
            ('commits folder a file', lambda d: (shutil.rmtree(os.path.join(d, 'commits')), wr('commits', b'x'))),
            ('refs a folder', lambda d: (os.remove(os.path.join(d, 'refs')), os.makedirs(os.path.join(d, 'refs'))))]
    return out


def s_damaged():
    print('-- damaged repositories: no crash, no hang, an answer to the end')
    base = tempfile.mkdtemp(prefix='dmg')
    run(BIN, base, ['--eval', MAKE])
    vc = os.path.join(base, 'BeeModel', 'v.bee.vc')
    cases = damage_cases(vc)
    worst = 0.0
    for k, (name, fn) in enumerate(cases):
        h = tempfile.mkdtemp(prefix='d')
        shutil.copytree(os.path.join(base, 'BeeModel'), os.path.join(h, 'BeeModel'), dirs_exist_ok=True)
        # (the case damages this copy: rebuild its lambdas' paths)
        d = os.path.join(h, 'BeeModel', 'v.bee.vc')
        cwd = os.getcwd()
        os.chdir(d)
        try:
            damage_cases(d)[k][1](d)
        finally:
            os.chdir(cwd)
        t0 = time.time()
        p = run(BIN, h, ['--eval', PROBE], timeout=120)
        worst = max(worst, time.time() - t0)
        shutil.rmtree(h, True)
        ok = clean(p) and '\nc ' in '\n' + p[0]
        check(ok, f'{name}: BeeModel answers to the end (rc {p[2]}{", " + (p[1] or "")[-200:] if p[2] else ""})')
    check(worst < 60, f'no hang: the slowest damaged case took {worst:.1f} s')
    shutil.rmtree(base, True)


# ---- random histories: clean runs, the same answers twice ------------------------------

NAMES = ['A', 'B', 'C', 'Ball']
BRANCHES = ['main', 'b', 'c']


def random_script(rnd, n):
    out = ['add("sphere", "Ball", 2, 1, 0)', 'add("cube", "A", -2, 0.5, 0)', 'material("Gold")', 'material("Red")',
           'op("file.save", "~/BeeModel/v.bee")', 'op("vc.commit", "start")', 'op("vc.branch", "b")', 'op("vc.branch", "c")']
    for k in range(n):
        r = rnd.random()
        nm = rnd.choice(NAMES)
        g = f'if exists("{nm}") {{ %s }}'
        if r < 0.10:
            out.append(f'if exists("{nm}") == 0 {{ add("{rnd.choice(["cube", "sphere"])}", "{nm}", {rnd.randint(-4, 4)}, 1, {rnd.randint(-4, 4)}) }}')
        elif r < 0.20:
            out.append(g % f'move("{nm}", {rnd.randint(-4, 4)}, {rnd.randint(0, 3)}, {rnd.randint(-4, 4)})')
        elif r < 0.25:
            out.append(g % f'set("{nm}", "{rnd.choice(["color", "hidden"])}", {rnd.choice([0, 1, 255, 65280])})')
        elif r < 0.30:
            out.append(g % f'delete("{nm}")')
        elif r < 0.34:
            out.append(g % f'vmove("{nm}", 0, {rnd.randint(-1, 1)}, 1, 0)')
        elif r < 0.38:
            out.append(g % f'assign("{nm}", "{rnd.choice(["Gold", "Red"])}")')
        elif r < 0.41:
            out.append(f'matset("{rnd.choice(["Gold", "Red"])}", "base", {rnd.random():.2f}, 0.5, 0.5)')
        elif r < 0.44:
            new = rnd.choice(NAMES)
            out.append(f'if exists("{nm}") {{ if exists("{new}") == 0 {{ rename("{nm}", "{new}") }} }}')
        elif r < 0.60:
            # (only with a change the diff sees, or merging)
            out.append(f'op("vc.diff")\nif vcinfo(9) == 1 {{ op("vc.commit", "c{k}") }} else {{ if vcinfo(3) > 0 {{ op("vc.commit", "c{k}") }} }}\nop("vc.diff", "off")')
        elif r < 0.65:
            out.append(f'op("vc.branch", "{rnd.choice(BRANCHES)}")')
        elif r < 0.75:
            br = rnd.choice(BRANCHES)
            out.append(f'op("vc.diff")\nif vcinfo(3) > 0 {{ op("vc.switch", "{br}") }} else {{ op("vc.switch", "{br} force") }}\nop("vc.diff", "off")'
                       if rnd.random() < 0.5 else f'op("vc.switch", "{br} force")')
        elif r < 0.85:
            out.append(f'op("vc.merge", "{rnd.choice(BRANCHES)}")')
        elif r < 0.90:
            out.append(f'op("vc.resolve", "{rnd.choice(["all", "1", "2", "3"])} {rnd.choice(["ours", "theirs"])}")')
        elif r < 0.93:
            out.append('op("vc.abort")')
        else:
            out.append(f'op("vc.diff", "{rnd.choice(BRANCHES + ["off", ""])}{rnd.choice(["", " side"])}")')
        out.append(f'print("s{k}", vcinfo(1), vcinfo(2), vcinfo(3), vcinfo(4), vcinfo(5), vcinfo(6), vcinfo(7), vcinfo(8), vcinfo(9), vctext(0), vctext(3), vctext(1, 0), vctext(2, 0), count())')
        out.append(f'if exists("{nm}") {{ print("o{k}", get("{nm}", "x"), get("{nm}", "y"), get("{nm}", "color"), get("{nm}", "hidden"), matof("{nm}")) }}')
    return '\n'.join(out) + '\n'


def s_random():
    n = int(os.environ.get('VC_RANDOM', '12'))
    print(f'-- random histories: {n} scripts of edits, commits, branches, switches, merges, resolves')
    rnd = random.Random(int(os.environ.get('VC_SEED', '7')))
    good = 0
    for k in range(n):
        code = random_script(rnd, 60)
        p, h1 = script(code)
        q, h2 = script(code)
        steps = len(lines(p[0]).get('s59', []))
        ok = clean(p) and steps == 1 and len([x for x in (p[0] or '').splitlines() if re.match(r's\d+ ', x)]) == 60
        same = ok and clean(q) and q[0] == p[0]
        good += same
        if not same:
            print(f'     script {k}: rc {p[2]} / {q[2]}, {"every step printed" if ok else "steps missing"}, '
                  f'{"the same twice" if q[0] == p[0] else "two runs differ"}; {(p[1] or "")[-200:]}')
            pl, ql = (p[0] or '').splitlines(), (q[0] or '').splitlines()
            for a, b in zip(pl, ql):
                if a != b:
                    print('     first:', a)
                    print('     again:', b)
                    break
            d = os.path.join(T, f'random{k}.bees')
            with open(d, 'w') as f:
                f.write(code)
            print('     (kept as', d, ')')
        for h in (h1, h2):
            shutil.rmtree(h, True)
    check(good == n, f'clean runs, every step printed, the same answers twice: {good} of {n} random histories')


STALE = '''
add("cube", "A", 0, 0, 0)
add("cube", "B", 2, 0, 0)
op("file.save", "~/BeeModel/v.bee")
op("vc.commit", "five")
op("vc.branch", "b")
op("vc.switch", "b")
delete("B")
op("vc.commit", "four")
op("vc.switch", "main force")
vmove("B", 0, 1, 1, 1)
op("vc.diff")
op("vc.switch", "b force")
op("vc.commit", "again")
print("x", vcinfo(1), vctext(3))
op("vc.switch", "main force")
vmove("B", 0, 1, 1, 1)
op("vc.diff")
op("vc.switch", "b force")
op("vc.switch", "main")
print("y", vctext(0))
'''


def s_stale():
    print('-- "nothing changed" by value: the stale bytes of a chunk entry\'s padding left out')
    p, home = script(STALE)
    lp = lines(p[0])
    check(clean(p) and lp.get('x') == ['2 four'] and lp.get('y') == ['main'],
          f'a switch and a commit with nothing changed - no commit, no refusal ({lp.get("x")}, {lp.get("y")})')
    shutil.rmtree(home, True)


# ---- the window: the viewport's diff and merge panel, the Versions editor ----------------

US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53}


def type_text(prog, s):
    for ch in s:
        prog.f.key(US[ch])
        prog.f.pump(0.02)
    prog.pump(0.2)


def widgets(prog):
    t, _ = prog.tool('ui_tree')
    try:
        return json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        return []


def find_w(prog, label, kind=None, nth=0):
    ws = [w for w in widgets(prog) if w.get('label') == label and (kind is None or w.get('kind') == kind)]
    return ws[nth] if len(ws) > nth else None


def click_w(prog, label, kind=None, nth=0):
    w = find_w(prog, label, kind, nth)
    if not w:
        return False
    prog.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    prog.pump(0.3)
    return True


def colour_count(im, c, box, tol=40):
    return sum(1 for y in range(box[1], box[3], 2) for x in range(box[0], box[2], 2)
               if all(abs(im.getpixel((x, y))[i] - c[i]) < tol for i in range(3)))


def panel_rect(im, box):
    pts = [(x, y) for y in range(box[1], box[3]) for x in range(box[0], box[2]) if im.getpixel((x, y))[:3] == (0x1d, 0x20, 0x27)]
    if len(pts) < 500:
        return None
    return min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts) + 1, max(p[1] for p in pts) + 1


def shot(prog, name):
    im = prog.image()
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        im.save(os.path.join(SHOTS, f'{name}.png'))
    return im


def viewport_box(prog):
    """The 3D view's rectangle (ui_tree records its editor button, 4, 2 into the area)."""
    for w in widgets(prog):
        if w.get('kind') == 'editor' and w.get('label') == '3D Viewport':
            return w['x'] - 4, w['y'] + 20, 1024, 630
    return 214, 80, 1014, 620


def s_window():
    print('-- the window: the diff\'s ghosts and list, the merge panel')
    p = Prog()
    try:
        p.ev('add("sphere", "Ball", 2, 1, 0)\nview(30, 25, 14, 0, 0.5, 0)')
        p.op('file.save', p.home + '/BeeModel/w.bee')
        p.op('vc.commit', 'first')
        p.op('vc.branch', 'agent')
        p.op('vc.switch', 'agent')
        p.ev('move("Ball", 4, 2, 0)\nadd("cube", "Tower", -3, 1.5, 0)\nscale("Tower", 0.5, 1.5, 0.5)\ndelete("Cube")')
        p.op('vc.commit', 'agent: a tower')
        p.op('vc.switch', 'main')
        vb = viewport_box(p)
        p.op('vc.diff', 'agent')
        p.pump(0.6)
        im = shot(p, 'diff_overlay')
        b = dict(red=colour_count(im, (0xe0, 0x50, 0x50), vb), yellow=colour_count(im, (0xe0, 0xc0, 0x40), vb),
                 green=colour_count(im, (0x50, 0xd0, 0x70), vb, 30), panel=panel_rect(im, vb), vb=vb)
        p.op('vc.diff', 'agent side')
        p.ev('view(30, 25, 40, 8, 0.5, 0)')   # (far enough out for the other side)
        p.pump(0.6)
        im = shot(p, 'diff_side')
        mid = (vb[0] + vb[2]) // 2
        b['grey'] = colour_count(im, (0x8a, 0x8f, 0x99), (mid, vb[1], vb[2], vb[3]))
        b['side_red'] = sum(1 for y in range(vb[1], vb[3]) for x in range(vb[0], vb[2])
                            if all(abs(im.getpixel((x, y))[i] - (0xe0, 0x50, 0x50)[i]) < 3 for i in range(3)))
        p.ev('view(30, 25, 14, 0, 0.5, 0)')
        p.op('vc.diff', 'off')
        p.pump(0.4)
        im = shot(p, 'diff_off')
        b['after_off'] = panel_rect(im, vb)
        check(b['red'] > 20, f'overlay: the removed object\'s ghost, red ({b["red"]})')
        check(b['yellow'] > 100, f'overlay: the changed one\'s old place, yellow ({b["yellow"]})')
        check(b['green'] > 20, f'overlay: the added object, green ({b["green"]})')
        pb = b['panel']
        check(pb and pb[2] - pb[0] == 370 and pb[3] - pb[1] == 3 * 18 + 30 and vb[2] - pb[0] == 380,
              f'the list: 370 wide, 380 in from the right, 18 a row and 30 ({pb})')
        check(b['side_red'] > 20, f'side by side: the removed one\'s ghost ({b["side_red"]})')
        check(b['grey'] > 50, f'side by side: the other version beside the scene, grey ({b["grey"]})')
        check(b['after_off'] is None, 'vc.diff off: the list and the ghosts go (the view\'s cache follows)')
        # the merge panel and its buttons
        p.ev('set("Ball", "y", 5)\nop("vc.commit", "main lifts the ball")\nop("vc.merge", "agent")')
        p.pump(0.6)
        im = shot(p, 'merge_panel')
        pr = panel_rect(im, vb)
        sp = [pr]
        if pr:
            y0 = pr[1] + 4 + 20
            p.click(pr[2] - 30, y0 + 8)
            sp.append(p.ev('print(vcinfo(8), get("Ball", "y"))'))
            im = shot(p, 'merge_theirs')
            sp.append(colour_count(im, (0x6a, 0x54, 0x20), (pr[2] - 55, y0, pr[2] - 5, y0 + 16), 8))
            p.click(pr[2] - 85, y0 + 8)
            sp.append(p.ev('print(vcinfo(8), get("Ball", "y"))'))
            im = shot(p, 'merge_ours')
            sp.append(colour_count(im, (0x6a, 0x54, 0x20), (pr[2] - 110, y0, pr[2] - 60, y0 + 16), 8))
        check(sp[0] and sp[0][3] - sp[0][1] == 48, f'the merge panel: a heading and a row ({sp[0]})')
        check(len(sp) == 5 and sp[1] == '0 2' and sp[2] > 50, f'"theirs" takes their value and lights ({sp[1:3]})')
        check(len(sp) == 5 and sp[3] == '0 5' and sp[4] > 50, f'"ours" ours again ({sp[3:5]})')
        p.op('edit.undo')
        r = p.ev('print(vcinfo(8), get("Ball", "y"))')
        check(r == '0 2', f'undo: the press on "ours" was one step ({r})')
        p.op('vc.abort')
        r = p.ev('print(vcinfo(9), vcinfo(7), get("Ball", "y"), count())')
        check(r == '0 0 5 4', f'vc.abort: the scene as before the merge ({r})')
        p.pump(0.4)
        gone = panel_rect(shot(p, 'aborted'), vb)
        check(gone is None, f'the panel goes with the merge ({gone})')
        # edit mode, then a switch underneath it (an agent's): no crash, the mesh shown
        p.click(600, 350)
        p.f.key(15)   # Tab
        p.pump(0.3)
        p.op('vc.switch', 'agent force')
        p.pump(0.5)
        p.f.key(15)
        p.pump(0.3)
        check(p.alive() and p.ev('print(vctext(0), count())') == 'agent 4', 'a switch while in edit mode: BeeModel goes on')
        p.op('edit.undo')
        p.pump(0.3)
        check(p.alive() and p.ev('print(count(), exists("Cube"))') == '4 1', 'and undo of it')
    finally:
        p.close()


def s_editor():
    print('-- the Versions editor: its rows, its buttons')
    p = Prog()
    try:
        p.op('area.type_versions', '')
        p.pump(0.5)

        def rows(prog):
            ws = [w for w in widgets(prog) if w.get('kind') in ('text', 'button', 'row', 'toggle', 'checkbox')]
            host = [w for w in ws if w.get('label') == 'Host']
            lan = [w for w in ws if w.get('label') == 'Host on LAN']
            if not host or not lan:
                return []
            col, right = host[0]['x'], lan[0]['x'] + lan[0]['w']
            out = []
            for w in ws:
                if w['y'] < 80 or w['y'] > 600 or w['x'] < col or w['x'] + w['w'] > right + 2:  # (above the console)
                    continue
                k = {'toggle': 'checkbox'}.get(w['kind'], w['kind'])
                out.append((k, w.get('label', ''), w['x'] - col, w['y'], w['h']))
            return out

        def rows_ok(name, want=()):
            rp = rows(p)
            labels = {r[1] for r in rp}
            # (no two widgets on top of each other: each row's top below the last one's)
            boxes = sorted((y, x, h) for k, l, x, y, h in rp)
            overlap = [(a, b) for a, b in zip(boxes, boxes[1:]) if a[1] == b[1] and b[0] < a[0] + a[2]]
            ok = len(rp) > 3 and set(want) <= labels and not overlap
            check(ok, f'{name}: the column\'s widgets ({len(rp)}; {sorted(set(want) - labels) or "all"} wanted there; {len(overlap)} overlap)')
            if not ok:
                print('     ', rp)
        rows_ok('no file', ('Host', 'Host on LAN'))
        p.ev('add("sphere", "Ball", 2, 1, 0)')
        p.op('file.save', p.home + '/BeeModel/w.bee')
        p.pump(0.4)
        rows_ok('a file, no commits', ('Commit',))
        # type a message, Commit
        click_w(p, '', 'text') or click_w(p, None, 'text')
        type_text(p, 'first one')
        click_w(p, 'Commit')
        p.pump(0.5)
        r = p.ev('print(vcinfo(1), vctext(3))')
        check(r == '1 first one', f'the message typed, Commit: a commit with it ({r})')
        p.op('vc.branch', 'agent')
        p.pump(0.4)
        rows_ok('two branches, a commit', ('main', 'agent'))
        click_w(p, 'agent', 'row')
        p.pump(0.5)
        r = p.ev('print(vctext(0))')
        check(r == 'agent', f'a click on a branch\'s row switches to it ({r})')
        p.ev('move("Ball", 4, 2, 0)')
        p.op('vc.commit', 'agent moves the ball')
        click_w(p, 'main', 'row')
        p.pump(0.5)
        p.ev('set("Ball", "y", 5)')
        w = find_w(p, 'Show what changed since the last commit')
        p.click(w['x'] + 5, w['y'] + 10)
        p.pump(0.5)
        r = p.ev('print(vctext(0), vcinfo(3), vctext(1, 0))')
        check(r == 'main 1 ~ Ball: transform', f'the toggle shows what changed since the last commit ({r})')
        w = find_w(p, 'Show what changed since the last commit')
        p.click(w['x'] + 5, w['y'] + 10)
        p.pump(0.5)
        p.op('vc.commit', 'main lifts the ball')
        p.op('vc.merge', 'agent')
        p.pump(0.5)
        r = p.ev('print(vcinfo(3), vcinfo(9), vcinfo(7))')
        check(r == '0 1 1', f'the toggle off; a merge with a conflict ({r})')
        rows_ok('merging, a conflict', ('Theirs', 'All Ours', 'Abort'))
        shot(p, 'editor_merge')
        click_w(p, 'Theirs')
        p.pump(0.5)
        r = p.ev('print(vcinfo(8), get("Ball", "y"), get("Ball", "x"))')
        check(r == '0 2 4', f'Theirs on the conflict\'s row ({r})')
        click_w(p, 'All Ours')
        p.pump(0.5)
        r = p.ev('print(vcinfo(8), get("Ball", "y"), get("Ball", "x"))')
        check(r == '0 5 2', f'All Ours ({r})')
        click_w(p, 'Abort')
        p.pump(0.5)
        r = p.ev('print(vcinfo(9), vcinfo(7))')
        check(r == '0 0', f'Abort ({r})')
        rows_ok('after the merge', ('main', 'agent'))
        # New Branch...: its form (Name, "feature")
        click_w(p, 'New Branch...')
        p.pump(0.5)
        shot(p, 'form_branch')
        p.f.key(28)   # Enter: the form's default
        p.pump(0.5)
        r = p.ev('print(vcinfo(2))')
        check(r == '3', f'New Branch...: its form, Enter makes "feature" ({r})')
    finally:
        p.close()


def main():
    print(f'versioned scenes: {BIN}, runs {RUNS}')
    try:
        if section('flow'):
            s_flow()
        if section('cross'):
            s_cross()
        if section('console'):
            s_console()
        if section('undo'):
            s_undo()
        if section('damaged'):
            s_damaged()
        if section('random'):
            s_random()
        if section('stale'):
            s_stale()
        if section('window'):
            s_window()
        if section('editor'):
            s_editor()
    finally:
        kill_all()
    print(f'\nversions fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
