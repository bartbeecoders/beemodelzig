#!/usr/bin/env python3
"""Tidy, Tidy with AI, the AI line-up of a reference set and Image to 3D
(outfolders.zig, refset.zig, hi3d.zig): BeeModel in the fake compositor
(tests/wl_fake.py), its own temp HOME and XDG folders, driven over MCP.

  tidy     outliner.tidy on a scene of kinds and names alike (lights, cameras,
           references, Chair / Chair.001 / Chair_2, children, folders there
           already, empty folders): every request answered, the .bee after it
           reads back, undo puts the scene back, redo brings Tidy back, a
           second tidy, the 256-folder limit, odd names; the outliner's Tidy
           button in the window; folder colours
  tidyai   outliner.tidy_ai, object.references_ai: what they hand the AI
           Assistant (a fake claude on PATH records it); the assistant may
           not be there yet: then its message is checked
  refview  reference_view: an answer to every request, a readable picture
           with the drawings, errors for what is no reference, its arguments
           (a part, out of range, not numbers, reversed)
  hi3d     object.from_image / refine_from_image with a fake helper
           ($BEEMODEL_HI3D, tests/files/fake_hi3d.py): the arguments it gets,
           the model placed, the refined one in the rough one's place, the
           status bar chip and its stop (TERM, then KILL for a helper that
           will not stop), a crash, an error, garbage, a flood of lines, no
           mesh, a bad mesh; undo of the placed model; the log
  fuzz     random tidy / folder / reference_view steps and random helper
           output: no crash, every request answered

    python3 tests/aitools.py BIN [runs=1]

BEE_CPU (default 14) pins BeeModel; AIT_ONLY=tidy,... runs some sections.
"""
import base64, io, json, os, random, shutil, struct, sys, time, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault('BEE_CPU', '14')
_argv = sys.argv
sys.argv = _argv[:2]   # (tests/mcp.py reads BIN from the command line when imported)
import mcp as M  # noqa: E402 (BeeModel in its fake compositor, its MCP client; temphome first)
sys.argv = _argv
import beefile  # noqa: E402

RUNS = int(_argv[2]) if len(_argv) > 2 else 1
ONLY = [x for x in os.environ.get('AIT_ONLY', '').split(',') if x]
NFUZZ = int(os.environ.get('AIT_FUZZ', '120'))
FAILS = []
NOTES = []
FAKE = os.path.join(HERE, 'files', 'fake_hi3d.py')

# a fake claude: what it was asked, kept in its HOME (never the real one)
with open(os.path.join(M.STUBS, 'claude'), 'w') as _f:
    _f.write('#!/usr/bin/env python3\nimport json, os, sys\n'
             'p = os.path.join(os.environ.get("HOME", "/tmp"), "claude_calls.jsonl")\n'
             'open(p, "a").write(json.dumps(sys.argv[1:]) + "\\n")\n'
             'print(json.dumps({"type": "result", "subtype": "success", "result": "Done (fake).", "is_error": False}))\n')
os.chmod(os.path.join(M.STUBS, 'claude'), 0o755)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def section(n):
    return not ONLY or n in ONLY


def png(path, w, h, lines=True, seed=0):
    """An RGB PNG: white, thin dark lines (a drawing), a few colours."""
    rnd = random.Random(seed)
    rows = []
    for y in range(h):
        r = bytearray([0])
        for x in range(w):
            c = (255, 255, 255)
            if lines and (x % 97 == 0 or y % 61 == 0 or x == y):
                c = (rnd.randint(0, 40), rnd.randint(0, 40), rnd.randint(0, 60))
            elif (x // 50 + y // 50) % 7 == 0:
                c = (200, 120 + x % 50, 90)
            r += bytes(c)
        rows.append(bytes(r))
    raw = zlib.compress(b''.join(rows), 6)

    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', raw) + ch(b'IEND', b''))


def answer(r):
    """A reply's (text, isError), or None when it is no answer."""
    try:
        res = json.loads(r)['result']
        return res['content'][0]['text'], res.get('isError')
    except (TypeError, ValueError, KeyError, IndexError):
        return None


class One:
    """BeeModel in its fake compositor (a fake helper as $BEEMODEL_HI3D if asked)."""

    def __init__(self, perm='files', hi3d=None):
        self.helper = None
        if hi3d:
            d = os.path.join(M.T, f'hz_{len(os.listdir(M.T))}')
            os.makedirs(d)
            shutil.copy(FAKE, os.path.join(d, 'bee-hi3d'))
            os.chmod(os.path.join(d, 'bee-hi3d'), 0o755)
            os.environ['BEEMODEL_HI3D'] = os.path.join(d, 'bee-hi3d')
            self.helper = d
        else:
            os.environ.pop('BEEMODEL_HI3D', None)
        self.p = M.Prog(perm=perm)
        os.environ.pop('BEEMODEL_HI3D', None)

    def tool(self, name, args=None, what=None, quiet=False, error=None):
        """A request: answered (and an error or not, when asked)."""
        line = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}})
        b = self.p.raw(line)
        self.last = M.norm(b, self.p.home)
        a = answer(b)
        ok = a is not None and (error is None or bool(a[1]) == error)
        if not ok and (not quiet or os.environ.get('AIT_VERBOSE')):
            print('     reply:', (self.last or 'None')[:700])
        if not quiet:
            check(ok, (what or f'{name} {json.dumps(args or {})[:80]}') + ': answered' + ('' if error is None else ' with an error' if error else ' without an error'))
        return ok

    def state(self):
        """The scene as scene_summary gives it, and the saved file's folders (FOLD)."""
        f = self.save()
        try:
            fold = beefile.chunk(f, b'FOLD')
        except Exception:  # noqa: BLE001
            fold = 'unreadable'
        return self.summary(), fold

    def summary(self):
        t = answer(self.p.raw(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'scene_summary', 'arguments': {}}})))
        return M.norm(t[0], self.p.home) if t else None

    def save(self):
        n = f'f{len(os.listdir(self.p.home))}.bee'
        self.tool('op_file_save_as', {'arg': '$HOME/' + n}, quiet=True)
        return os.path.join(self.p.home, n)

    def bee(self, what):
        """It saves; the file reads back, its objects those of the scene."""
        f = self.save()
        try:
            objs = beefile.objects(f)
            s = json.loads(self.summary() or 'null')
            want = sorted(o['name'] for o in s['objects']) if s else None
            got = sorted(o['name'].decode('utf-8', 'replace') if isinstance(o['name'], bytes) else o['name'] for o in objs)
            ok, why = got == want, '' if got == want else f': {got[:6]} / the scene {(want or [])[:6]}'
        except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
            ok, why = False, f' ({e})'
        check(ok, f'{what}: the .bee reads back with the scene\'s objects' + why)
        return f

    def close(self):
        self.p.close()


# ---- Tidy ---------------------------------------------------------------------------

def tidy_scene(T, k=0):
    for nm in ('Chair', 'Chair.001', 'Chair_2', 'Chair 3', 'Table', 'Table.003', 'Lamp', '123', '123', 'Wall - 1', 'Wall-2',
               'Stühl.001', 'Stühl.002', 'A' * 31, 'A' * 30 + '1', 'Kid', 'Kid.001', 'Mine', 'Mine.001'):
        T.tool('create_primitive', {'type': 'cube', 'name': nm}, quiet=True)
    for t, nm in (('light', 'Key'), ('light', 'Fill'), ('camera', 'Cam'), ('camera', 'Cam2'), ('sphere', 'Ball')):
        T.tool('create_primitive', {'type': t, 'name': nm}, quiet=True)
    # children stay with their parents
    T.tool('run_operator', {'id': 'object.parent_set', 'arg': 'Kid Table'}, quiet=True)
    # a folder there already, with two in it; an empty one with an empty one in it
    T.tool('select', {'names': ['Mine', 'Mine.001']}, quiet=True)
    T.tool('run_operator', {'id': 'outliner.folder_new', 'arg': 'Mine'}, quiet=True)
    T.tool('select', {'names': []}, quiet=True)
    T.tool('run_operator', {'id': 'outliner.folder_new', 'arg': 'Empty'}, quiet=True)
    T.tool('run_operator', {'id': 'outliner.folder_new', 'arg': 'Inner'}, quiet=True)
    T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': 'teal Mine'}, quiet=True)


def ui_widget(p, label, kind='button'):
    t, _, _ = p.tool('ui_tree')
    try:
        w = json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        return None
    b = [x for x in w if x.get('kind') == kind and x.get('label') == label]
    return b[0] if b else None


def s_tidy():
    print('-- Tidy: loose objects into coloured folders')
    T = One()
    try:
        tidy_scene(T)
        T.bee('the scene before')
        before = T.state()
        T.tool('op_outliner_tidy', {}, 'outliner.tidy', error=False)
        T.bee('after Tidy')
        tidied = T.state()
        check(tidied[0] is not None and tidied[1] != before[1], 'Tidy changed the folders')
        T.tool('undo', {}, 'undo Tidy (one step)')
        check(T.state() == before, 'undo puts the scene and its folders back as they were before Tidy')
        T.bee('after undo')
        T.tool('redo', {}, 'redo Tidy')
        check(T.state() == tidied, 'redo brings Tidy back')
        T.bee('after redo')
        for nm in ('Chair.009', 'Chair.010', 'Bench', 'Bench.001', 'Key2', 'Key3'):
            T.tool('create_primitive', {'type': 'light' if nm.startswith('Key') else 'cube', 'name': nm}, quiet=True)
        T.tool('op_outliner_tidy', {}, 'a second Tidy: into the folders there, a new one coloured on')
        T.bee('after the second Tidy')
        second = T.state()
        T.tool('op_outliner_tidy', {}, 'a third Tidy: nothing left to do')
        check(T.state() == second, 'the third Tidy left the scene as it was')
        T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': 'next Chair'}, 'folder_color next (by name)')
        T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': 'pink'}, 'folder_color with no folder picked')
        T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': 'mauve Chair'}, 'folder_color: an unknown colour')
        T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': 'red Nope'}, 'folder_color: no folder of that name')
        T.tool('run_operator', {'id': 'outliner.folder_color', 'arg': ''}, 'folder_color with nothing')
        T.bee('folder colours')
        # the outliner's Tidy button in the window
        T.tool('op_file_new', {}, quiet=True)
        tidy_scene(T, 1)
        T.p.pump(0.4)
        b = ui_widget(T.p, 'Tidy')
        check(b is not None, 'the outliner shows Tidy')
        if b:
            M.click(T.p, b['x'] + b['w'] // 2, b['y'] + b['h'] // 2)
        f = T.bee('the Tidy button clicked')
        fold = beefile.chunk(f, b'FOLD') or b''
        check(b'Chair' in fold and b'Lights' in fold, 'the click tidied (a Chair and a Lights folder in FOLD)')
        shots = os.environ.get('AIT_SHOTS')
        if shots:
            T.p.pump(0.4)
            T.p.image().save(f'{shots}/tidy.png')
        # the 256-folder limit: no room for the groups
        T.tool('op_file_new', {}, quiet=True)
        for nm in ('Pot', 'Pot.001', 'Pan', 'Pan.001'):
            T.tool('create_primitive', {'type': 'cube', 'name': nm}, quiet=True)
        T.tool('select', {'names': []}, quiet=True)
        for i in range(255):
            T.tool('run_operator', {'id': 'outliner.folder_new', 'arg': f'F{i}'}, quiet=True)
        T.tool('select', {'names': ['Pot']}, quiet=True)
        T.tool('run_operator', {'id': 'outliner.folder_new', 'arg': 'Keep'}, quiet=True)
        T.tool('op_outliner_tidy', {}, 'Tidy with 256 folders: no room (the empty ones go after)')
        check('folders: 256 at most' in (T.last or ''), 'it said so: "folders: 256 at most"')
        T.bee('after Tidy at the limit')
        check(T.p.alive(), 'still running')
    finally:
        T.close()


# ---- the AI's side ------------------------------------------------------------------

def calls(p):
    f = os.path.join(p.home, 'claude_calls.jsonl')
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def ai_prompt(argv):
    return argv[argv.index('-p') + 1] if '-p' in argv else None


def refs_folder(T, n=4):
    """A folder of drawings, imported (object.add_references): a reference set."""
    d = os.path.join(T.p.home, 'drawings')
    os.makedirs(d, exist_ok=True)
    for k, (nm, w, h) in enumerate([('Voorgevel', 900, 400), ('Plattegrond begane grond', 800, 600), ('Doorsnede A', 700, 350), ('Achtergevel', 2600, 900)][:n]):
        png(os.path.join(d, nm + '.png'), w, h, seed=k)
    T.tool('op_object_add_references', {'arg': '$HOME/drawings'}, quiet=True)   # (it runs as a job: its lines later)
    ok = wait_for(T, lambda p: sum(1 for x in names(p) if x.startswith('Ref ')) == n, 20)
    check(ok, f'object.add_references: {n} references')


def s_tidyai():
    print('-- Tidy with AI, Line Up References with AI: what the AI Assistant is handed')
    T = One()
    try:
        T.tool('op_object_references_ai', {}, 'references_ai with no references: the message')
        refs_folder(T)
        cf = os.path.join(T.p.home, 'claude_calls.jsonl')
        if os.path.exists(cf):
            os.remove(cf)
        for op in ('outliner.tidy_ai', 'object.references_ai'):
            M.console(T.p, op)
            for _ in range(10):
                if calls(T.p):
                    break
                T.p.pump(0.2)
            cp = calls(T.p)
            if cp:
                pp = ai_prompt(cp[-1])
                check(bool(pp and pp.strip()), f'{op}: a prompt handed to the AI ({len(pp or "")} bytes)')
            else:
                NOTES.append(f'{op}: no AI Assistant yet: the prompt it hands over is not checked')
                print(f'  note {op}: no AI Assistant yet (its prompt not checked)')
            if os.path.exists(cf):
                os.remove(cf)
            for _ in range(20):
                T.p.pump(0.2)
        check(T.p.alive(), 'still running')
    finally:
        T.close()


# ---- reference_view -----------------------------------------------------------------

def pixels(reply):
    """The picture of a reply: (w, h, RGB bytes) or None."""
    from PIL import Image
    try:
        c = json.loads(reply)['result']['content']
    except (TypeError, ValueError, KeyError):
        return None
    im = [x for x in c if x.get('type') == 'image']
    if not im:
        return None
    try:
        i = Image.open(io.BytesIO(base64.b64decode(im[0]['data']))).convert('RGB')
    except Exception:   # (not a picture at all)
        return 'unreadable', b''
    return i.size, i.tobytes()


def s_refview():
    print('-- reference_view: the text, the picture, the arguments')
    T = One()
    try:
        refs_folder(T)
        # (args, what, an error or None for either)
        cases = [({}, 'no name', True), ({'name': ''}, 'an empty name', True), ({'name': 'Nope'}, 'no such object', True), ({'name': 5}, 'a number for the name', True),
                 ({'name': 'Ref voorgevel'}, 'a whole drawing', False), ({'name': 'Ref voorgevel', 'x0': 100, 'y0': 50, 'x1': 300, 'y1': 200}, 'a part of it', False),
                 ({'name': 'Ref voorgevel', 'x0': 300, 'x1': 100}, 'x1 before x0 (a pixel)', None), ({'name': 'Ref voorgevel', 'x0': -50, 'y0': -1e9, 'x1': 1e12, 'y1': 'x'}, 'out of range, not a number', None),
                 ({'name': 'Ref voorgevel', 'x0': 899, 'y0': 399}, 'the last pixel', None), ({'name': 'Ref voorgevel', 'x0': 10.9, 'y1': 20.7}, 'fractions (cut)', None),
                 ({'name': 'Ref plattegrond begane gr'}, 'a plan (flat)', False), ({'name': 'Ref doorsnede a'}, 'a section (hidden)', None),
                 ({'name': 'x' * 100}, 'a 100-byte name', True), ({'name': 'Ref achtergevel'}, '2600 px wide', False),
                 ({'name': 'Ref achtergevel', 'x0': 1000, 'x1': 1100, 'y0': 400, 'y1': 420}, 'a small part of the wide one', None), ({'name': 'Ref voorgevel', 'x0': None, 'y0': [1]}, 'null and a list', None)]
        for args, what, err in cases:
            line = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'reference_view', 'arguments': args}})
            b = T.p.raw(line)
            a = answer(b or '')
            ok = a is not None and (err is None or bool(a[1]) == err)
            if not ok:
                print('     reply:', (M.norm(b, T.p.home) or '')[:500])
            check(ok, f'reference_view, {what}: answered' + ('' if err is None else ' with an error' if err else ' without an error'))
            pb = pixels(b or '')
            if err is False:
                check(pb is not None, f'reference_view, {what}: a picture comes with it')
            if pb:
                sz = pb[0]
                check(sz != 'unreadable' and 0 < sz[0] <= 1024 and 0 < sz[1] <= 1024 and len(pb[1]) == sz[0] * sz[1] * 3,
                      f'reference_view, {what}: the picture reads back, 1024 px a side at most ({sz})')
        T.tool('create_primitive', {'type': 'cube', 'name': 'Box'}, quiet=True)
        T.tool('reference_view', {'name': 'Box'}, 'reference_view of an object that is no reference', error=True)
        check(T.p.alive(), 'still running')
    finally:
        T.close()


# ---- Image to 3D --------------------------------------------------------------------

def set_mode(T, mode):
    d = T.helper
    open(os.path.join(d, 'mode'), 'w').write(mode)
    if os.path.exists(os.path.join(d, 'args.json')):
        os.remove(os.path.join(d, 'args.json'))


def chip(p):
    """The status bar's Image to 3D chip, or None."""
    t, _, _ = p.tool('ui_tree')
    try:
        w = json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        return None
    b = [x for x in w if x.get('kind') == 'chip' and (x.get('label') or '').startswith('Image to 3D')]
    return b[0] if b else None


def wait_for(T, cond, t=15.0):
    end = time.time() + t
    while time.time() < end:
        if cond(T.p):
            return True
        T.p.pump(0.1)
    return False


def names(p):
    s = p.scene()
    return [o['name'] for o in s['objects']] if s else []


def s_hi3d():
    print('-- Image to 3D: a fake helper, its lines, the model placed, the chip, stopping it')
    T = One(hi3d=True)
    p = T.p
    try:
        png(os.path.join(p.home, 'chair.png'), 64, 64, seed=3)
        # usage, a missing image, no addon (a helper that is not there)
        n0 = len(names(p))
        for cmd in ('object.from_image', 'object.from_image ' + '/nonexistent/x.png'):
            M.console(p, cmd)
        check(p.alive() and len(names(p)) == n0, 'no image, an image not there: nothing added')
        # a model: progress, done, placed at the 3D cursor (one undo step)
        set_mode(T, 'ok')
        # (the 3D cursor away from the origin, where the OBJ's own vertices are)
        T.tool('create_primitive', {'type': 'sphere', 'name': 'Here', 'location': [3, 0.5, -2]}, quiet=True)
        T.tool('run_operator', {'id': 'view.cursor_to_selected'}, quiet=True)
        M.console(p, f'object.from_image {p.home}/chair.png 1024')
        ok = wait_for(T, lambda p: 'chair' in names(p))
        check(ok, 'from_image: the model came in, named after the image')
        f = T.bee('from_image: the model in the scene')
        try:
            ob = {o['name']: o for o in beefile.objects(f)}
            okc = all(abs(x - y) < 1e-4 for x, y in zip(ob['chair']['loc'], ob['Here']['loc']))
            why = '' if okc else f": {ob['chair']['loc']} / {ob['Here']['loc']}"
        except Exception as e:  # noqa: BLE001
            okc, why = False, f' ({e})'
        check(okc, 'from_image: the model placed at the 3D cursor' + why)
        try:
            a = json.load(open(os.path.join(T.helper, 'args.json')))
        except (OSError, ValueError):
            a = None
        a = [x.replace(p.home, '$HOME') for x in a] if a else a
        print('     helper args:', a)
        check(bool(a) and a[:2] == ['run', '--image'] and '--out' in a and '--resolution' in a and a[a.index('--resolution') + 1] == '1024',
              'the helper got its arguments (run --image I --out O --resolution 1024)')
        lg = os.path.join(p.home, 'cache', 'beemodel', 'hi3d', 'hi3d.log')
        check(os.path.exists(lg) and '@bee done' in open(lg, errors='replace').read(), 'all the helper said is in the cache\'s hi3d.log')
        T.tool('undo', {}, 'undo the model (one step)')
        check('chair' not in names(p), 'after undo: the model is gone')
        T.tool('redo', {}, 'redo the model')
        check('chair' in names(p), 'after redo: it is back')
        # refine: the active mesh as the rough shape, the result in its place
        set_mode(T, 'refine')
        T.tool('create_primitive', {'type': 'cube', 'name': 'Block', 'location': [2, 1, -3], 'rotation_deg': [0, 30, 0], 'scale': [1, 2, 0.5]}, quiet=True)
        M.console(p, f'object.refine_from_image {p.home}/chair.png')
        ok = wait_for(T, lambda p: 'chair.001' in names(p))
        check(ok, 'refine_from_image: the refined mesh came in')
        f = T.bee('refine: the scene')
        try:
            ob = {o['name']: o for o in beefile.objects(f)}
            bl, ch = ob.get('Block'), ob.get('chair.001')
            okf = bl is not None and ch is not None and ch['flags'] & 0x201 == 0x1 and bl['flags'] & 0x201 == 0x200 and \
                all(abs(x - y) < 1e-4 for x, y in zip(bl['loc'], ch['loc']))
            why = '' if okf else f": Block {bl and (bl['loc'], hex(bl['flags']))}, chair.001 {ch and (ch['loc'], hex(ch['flags']))}"
        except Exception as e:  # noqa: BLE001
            okf, why = False, f' ({e})'
        check(okf, 'refine: the refined one selected, in the rough one\'s place; the rough one hidden and deselected' + why)
        check(os.path.exists(os.path.join(p.home, 'cache', 'beemodel', 'hi3d', 'coarse.obj')), 'the rough mesh written (coarse.obj)')
        # failures: the helper's error, a crash, no mesh, a missing / bad mesh, garbage, a flood
        for mode in ('error', 'crash', 'nomesh', 'missing', 'badobj', 'garbage', 'flood', 'spaces'):
            set_mode(T, mode)
            before = len(names(p))
            M.console(p, f'object.from_image {p.home}/chair.png')
            done = wait_for(T, lambda p: chip(p) is None, 30)
            p.pump(0.5)
            check(done, f'{mode}: the helper ended (no chip)')
            check(T.summary() is not None, f'{mode}: the scene answers after it')
            if mode in ('flood', 'spaces'):
                check(len(names(p)) == before + 1, f'{mode}: the model came in all the same')
            elif mode == 'garbage':
                check(len(names(p)) == before, 'garbage: no model (the unterminated done line is not a line)')
            else:
                check(len(names(p)) == before, f'{mode}: no model')
            shots = os.environ.get('AIT_SHOTS')
            if shots and mode == 'error':
                p.image().save(f'{shots}/hz_{mode}.png')
        # the chip, and a stop by clicking it
        for mode in ('slow', 'stuck'):
            set_mode(T, mode)
            M.console(p, f'object.from_image {p.home}/chair.png 512')
            wait_for(T, lambda p: chip(p) is not None, 10)
            p.pump(0.8)
            cp = chip(p)
            check(cp is not None, f'{mode}: the chip is there')
            if cp:
                lab = cp.get('label') or ''
                check(lab.startswith('Image to 3D: Carving the detail 42%'), f'{mode}: the chip says what the helper is doing ({lab})')
            if mode == 'slow':
                if cp:
                    M.click(p, cp['x'] + cp['w'] // 2, cp['y'] + cp['h'] // 2)
            else:
                T.tool('op_object_from_image_stop', {}, 'stuck: object.from_image_stop (TERM)')
            ok = wait_for(T, lambda p: chip(p) is None, 20)
            check(ok, f'{mode}: stopped (a stuck one by KILL) and the chip is gone')
        check(p.alive(), 'still running')
    finally:
        T.close()


# ---- fuzz ---------------------------------------------------------------------------

def s_fuzz():
    print(f'-- fuzz: {NFUZZ} random steps on the port')
    rnd = random.Random(77)
    d = os.path.join(M.T, 'hz_fuzz')
    os.makedirs(d)
    shutil.copy(FAKE, os.path.join(d, 'bee-hi3d'))
    os.environ['BEEMODEL_HI3D'] = os.path.join(d, 'bee-hi3d')
    p = M.Prog(perm='files')
    os.environ.pop('BEEMODEL_HI3D', None)
    try:
        png(os.path.join(p.home, 'i.png'), 32, 32)
        bad = 0
        for k in range(NFUZZ):
            c = rnd.random()
            if c < 0.25:
                r = p.tool('create_primitive', {'type': rnd.choice(['cube', 'light', 'camera']), 'name': rnd.choice(['A', 'A.001', 'B_2', '1', 'é' * 9, 'x' * 40])})[2]
            elif c < 0.4:
                r = p.tool('op_outliner_tidy', {})[2]
            elif c < 0.55:
                r = p.tool('run_operator', {'id': rnd.choice(['outliner.folder_new', 'outliner.folder_color', 'outliner.folder_delete', 'object.move_to_folder']),
                                            'arg': rnd.choice(['', 'red', 'next A', 'none', 'X', 'contents', 'pink ' + 'q' * 40])})[2]
            elif c < 0.65:
                r = p.tool('reference_view', {'name': rnd.choice(['A', '', 'i']), 'x0': rnd.choice([0, -1, 1e30, 'a']), 'x1': rnd.choice([1, 2, None])})[2]
            elif c < 0.75:
                r = p.tool(rnd.choice(['undo', 'redo']), {})[2]
            elif c < 0.85:
                open(os.path.join(d, 'mode'), 'w').write(rnd.choice(['ok', 'garbage', 'crash', 'error', 'slow', 'missing', 'badobj']))
                M.console(p, f'object.from_image {p.home}/i.png')
                r = 'console'
            else:
                r = p.tool('op_object_from_image_stop', {})[2]
            if r is None:
                bad += 1
            if not p.alive():
                break
            p.pump(0.05)
        check(p.alive() and bad == 0, f'{NFUZZ} steps: still running, every request answered ({bad} not)')
        p.tool('op_object_from_image_stop', {})
    finally:
        p.close()


def main():
    t0 = time.time()
    try:
        for name, fn in [('tidy', s_tidy), ('tidyai', s_tidyai), ('refview', s_refview), ('hi3d', s_hi3d), ('fuzz', s_fuzz)]:
            if section(name):
                fn()
    finally:
        shutil.rmtree(M.T, True)
    for n in NOTES:
        print('not verified:', n)
    print(f'aitools: {time.time() - t0:.0f} s, fails {len(FAILS)}')
    for f in FAILS:
        print('   ', f)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
