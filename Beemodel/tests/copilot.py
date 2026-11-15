#!/usr/bin/env python3
"""The procedural co-pilot (copilot.zig): BeeModel in its fake compositor
(tests/wl_fake.py, through tests/mcp.py's Prog), with its own temp HOME and XDG
folders, an MCP client on its socket. Every reply well-formed JSON-RPC 2.0.

  json      node_types, describe_graph (one tree, every tree, a missing one,
            odd arguments), bee://graphs, prompts/list, prompts/get, tools/list:
            the co-pilot's tools listed, the goal in the prompt, the trees as
            built (their nodes and links), the proposal in bee://graphs
  proposal  propose_begin / propose_end / proposal_status and their errors; the
            user's answer by Enter, Esc (waiting and while the agent still
            works), a click on the banner's Accept and Revert, the AI Activity
            header's Accept and Revert: accepted keeps what was made, reverted
            takes it away; undo takes an accepted proposal away in one step,
            redo brings it back; undo refused while a proposal is open; a
            failing request inside one
  look      the banner drawn while building and while waiting (its Accept
            button), gone after the answer
  files     a proposal accepted, then saved: the file reads back, opened again
            the same trees and scene
  perm      read-only agents may look and propose, not build
  fuzz      random proposal / tree / key sequences: no crash, it answers, the
            state is one of the five

    python3 tests/copilot.py BIN [runs=1]

BEE_CPU (default 14) pins BeeModel; COPILOT_ONLY=json,... runs some
sections; COPILOT_FUZZ (default 150) sets the fuzz's steps.
"""
import json, os, random, re, shutil, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault('BEE_CPU', '14')
import mcp as M  # noqa: E402 (the program in its fake compositor, its MCP client; temphome first)

RUNS = M.RUNS
ONLY = [x for x in os.environ.get('COPILOT_ONLY', '').split(',') if x]
NFUZZ = int(os.environ.get('COPILOT_FUZZ', '150'))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def section(n):
    return not ONLY or n in ONLY


class One:
    """BeeModel over MCP: each request's reply well formed."""

    def __init__(self, perm='files'):
        self.p = M.Prog(perm)

    def ask(self, line, what=None):
        """One request: its reply (checked well formed when `what` is given)."""
        r = self.p.raw(line, tag=True)
        bad = M.wellformed(r, 1)
        if what:
            if bad:
                print('     reply:', (r or 'None')[:600])
            check(not bad, what + (f' ({bad})' if bad else ''))
        return r

    def tool(self, name, args=None, what=None, quiet=False, err=None):
        """A tools/call: (text, isError). err: what isError must be."""
        line = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}})
        r = self.p.raw(line, tag=True)
        bad = M.wellformed(r, 1)
        t = e = None
        if not bad:
            try:
                res = json.loads(r)['result']
                t, e = res['content'][0]['text'], res['isError']
            except (KeyError, IndexError, TypeError, ValueError):
                bad = 'no result content'
        if not bad and err is not None and e != err:
            bad = 'an error' if e else 'no error'
        if what and not quiet:
            if bad:
                print('     reply:', (r or 'None')[:600])
            check(not bad, what + (f' ({bad})' if bad else ''))
        return t, e

    def state(self, what=None):
        """The proposal, the trees, the scene (checked well formed when `what` is given)."""
        out = []
        for n in ('proposal_status', 'describe_graph', 'scene_summary'):
            t, e = self.tool(n)
            t = M.norm(t, self.p.home)
            if n == 'describe_graph' and t:
                # (the trees alone: the proposal's state is proposal_status's)
                t = re.sub(r',"proposal":"[a-z ]*"', '', t)
            out.append(t)
        if what:
            check(all(x is not None for x in out), what)
        return tuple(out)

    def status(self):
        return self.tool('proposal_status')[0]

    def objects(self):
        sc = self.p.scene()
        return [o['name'] for o in sc['objects']] if sc else None

    def key(self, code):
        self.p.f.enter(600, 300)
        self.p.f.key(code)
        self.p.pump(0.3)

    def alive(self):
        return self.p.alive()

    def close(self):
        return self.p.close()


def gl(r):
    return json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': r[0], 'params': r[1]}) if len(r) > 1 else json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': r[0]})


def build(T, name='Fence', n=3):
    """A tree with nodes, links, constants and values (one MCP request each)."""
    T.tool('run_operator', {'id': 'tree.new', 'arg': name}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node', 'arg': f'{name} cube 1.5'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node', 'arg': f'{name} line {n} 2 0 0'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node', 'arg': f'{name} instance'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node', 'arg': f'{name} output'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.link', 'arg': f'{name} 2 3 1'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.link', 'arg': f'{name} 1 3 2'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.link', 'arg': f'{name} 3 4 1'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node_set', 'arg': f'{name} 3 3 0.25 0.5 -1e-3'}, quiet=True)
    T.tool('run_operator', {'id': 'tree.node_set', 'arg': f'{name} 1 4 2.125'}, quiet=True)


# ---- JSON ------------------------------------------------------------------------------

def links(tree):
    """[(node, slot, from node, its output)] of a describe_graph tree."""
    return [(n['node'], i['slot'], i['from']['node'], i['from']['output']) for n in tree['nodes'] for i in n['inputs'] if 'from' in i]


def prompt_text(r):
    try:
        return json.loads(r)['result']['messages'][0]['content']['text']
    except (TypeError, ValueError, KeyError, IndexError):
        return None


def s_json():
    print('-- JSON: the catalogue, the trees, bee://graphs, the prompts')
    P = One()
    try:
        r = P.ask(gl(('tools/list',)), 'tools/list')
        try:
            names = [t['name'] for t in json.loads(r)['result']['tools']]
        except (TypeError, ValueError, KeyError):
            names = []
        five = ['propose_begin', 'propose_end', 'proposal_status', 'node_types', 'describe_graph']
        check(all(n in names for n in five) and len(names) == len(set(names)), f'tools/list: the co-pilot\'s five, each name once ({[n for n in five if n not in names]} missing)')
        r = P.ask(gl(('prompts/list',)), 'prompts/list')
        check('"procedural"' in (r or '') and '"build_world"' in (r or ''), 'prompts/list: procedural, build_world')
        for goal, what in (('a fence along the path', 'a goal'), (None, 'no goal'), ('', 'an empty goal'), ('Zäune "ü" \\ \n\t' * 3, 'quotes, a backslash, UTF-8, control characters'),
                           ('x' * 700, 'a 700-byte goal'), ('é' * 300, 'a 600-byte UTF-8 goal')):
            params = {'name': 'procedural'}
            if goal is not None:
                params['arguments'] = {'goal': goal}
            t = prompt_text(P.ask(gl(('prompts/get', params)), f'prompts/get procedural: {what}'))
            if goal:
                head = goal[:40]
                check(t is not None and (head in t or head.replace('\n', ' ').replace('\t', ' ') in t or goal[:3] in t), f'prompts/get procedural, {what}: the goal is in the prompt')
        t = prompt_text(P.ask(gl(('prompts/get', {'name': 'nope', 'arguments': {'goal': 'x'}})), 'prompts/get of an unknown prompt'))
        check(t is not None and 'Goal: x' in t, 'prompts/get of an unknown prompt: the procedural one, with the goal')
        P.ask(gl(('prompts/get', {'arguments': {'goal': 5}})), 'prompts/get: a number for the goal, no name')
        P.ask(gl(('prompts/get', {'name': 'procedural', 'arguments': 'x'})), 'prompts/get: arguments not an object')
        t, _ = P.tool('node_types', {}, 'node_types: the geometry node catalogue')
        try:
            cat = {n['type']: n for n in json.loads(t)['geometry_nodes']}
        except (TypeError, ValueError, KeyError):
            cat = {}
        check(len(cat) > 10 and all([o['index'] for o in n['outputs']] == list(range(len(n['outputs']))) for n in cat.values()),
              f'node_types: {len(cat)} types, each one\'s outputs numbered from 0')
        P.tool('node_types', {'x': 1}, 'node_types with an argument it does not take', err=False)
        t, _ = P.tool('describe_graph', {}, 'describe_graph with no trees')
        check(t is not None and json.loads(t).get('trees') == [], f'describe_graph with no trees: none ({t})')
        P.ask(gl(('resources/read', {'uri': 'bee://graphs'})), 'bee://graphs with no trees')
        for r_ in range(RUNS):
            build(P, f'Fence{r_}' if r_ else 'Fence')
        build(P, 'Second tree, a long name for it', 5)
        P.tool('run_operator', {'id': 'tree.new', 'arg': 'Empty'}, quiet=True)
        t, _ = P.tool('describe_graph', {'tree': 'Fence'}, 'describe_graph of one tree')
        try:
            fence = json.loads(t)
        except (TypeError, ValueError):
            fence = {'nodes': []}
        lk = links(fence)
        check(sorted(lk) == [(3, 1, 2, 0), (3, 2, 1, 0), (4, 1, 3, 0)], f'the tree as built: four nodes, its three links ({len(fence["nodes"])} nodes, links {lk})')
        types = {n['node']: n['type'] for n in fence['nodes']}
        check(all(o < len(cat.get(types.get(f), {}).get('outputs', [])) for _, _, f, o in lk), 'each link from an output node_types lists for that node')
        vals = {n['node']: n['values'] for n in fence['nodes']}
        check(vals.get(1, [None])[0] == 2.125 and vals.get(2, [0, 0])[:2] == [3, 2], f'the values set: the cube 2.125, the line 3 2 ({vals.get(1)}, {vals.get(2)})')
        P.tool('run_operator', {'id': 'tree.group', 'arg': 'Fence 2 3'}, quiet=True)
        t, _ = P.tool('describe_graph', {}, 'describe_graph: every tree (nodes, links, constants, values, places, a group)')
        try:
            n = len(json.loads(t)['trees'])
        except (TypeError, ValueError, KeyError):
            n = -1
        check(n >= RUNS + 2, f'describe_graph: every tree ({n})')
        t, _ = P.tool('describe_graph', {'tree': 'Empty'}, 'describe_graph of an empty tree', err=False)
        P.tool('describe_graph', {'tree': 'Nope'}, 'describe_graph of a tree not there: the error', err=True)
        P.tool('describe_graph', {'tree': 'Fence '}, 'describe_graph: the name exactly (a space after it): not there', err=True)
        P.tool('describe_graph', {'tree': ''}, 'describe_graph with an empty name: every tree', err=False)
        P.tool('describe_graph', {'tree': 7}, 'describe_graph with a number for the name: every tree', err=False)
        P.tool('describe_graph', {'tree': 'F' * 200}, 'describe_graph with a 200-byte name: not there', err=True)
        r = P.ask(gl(('resources/read', {'uri': 'bee://graphs'})), 'bee://graphs: the trees and the proposal')
        try:
            g = json.loads(json.loads(r)['result']['contents'][0]['text'])
        except (TypeError, ValueError, KeyError, IndexError):
            g = {}
        check(g.get('proposal') == 'none' and len(g.get('trees', [])) == n, f'bee://graphs: the {n} trees and the proposal ({g.get("proposal")!r})')
        P.ask(gl(('resources/read', {'uri': 'bee://graphsX'})), 'resources/read of another uri')
        P.tool('run_operator', {'id': 'tree.node_move', 'arg': 'Fence 1 120 80'}, quiet=True)
        t, _ = P.tool('describe_graph', {'tree': 'Fence'}, 'describe_graph after a node moved')
        try:
            n1 = [x for x in json.loads(t)['nodes'] if x['node'] == 1][0]
        except (TypeError, ValueError, KeyError, IndexError):
            n1 = {}
        check((n1.get('x'), n1.get('y')) == (120, 80), f'the node\'s place: 120 80 ({n1.get("x")}, {n1.get("y")})')
        check(P.alive(), 'still running')
    finally:
        P.close()


# ---- the proposal ---------------------------------------------------------------------

def banner_click(P, which):
    """A click on the banner's Accept or Revert, found by its colour."""
    col = (0x3f, 0x8f, 0x5a) if which == 'accept' else (0x8f, 0x3f, 0x3f)
    p = P.p
    p.pump(0.5)
    im = p.image()
    pts = [(x, y) for y in range(100, 200) for x in range(0, im.size[0]) if im.getpixel((x, y)) == col]
    check(bool(pts), f'the banner\'s {which} button is drawn')
    if pts:
        M.click(p, sum(q[0] for q in pts) // len(pts), sum(q[1] for q in pts) // len(pts))


def header_click(P, which):
    """The AI Activity header's Accept / Revert buttons. (The viewport's area
    becomes the AI Activity a moment: wide enough for them.)"""
    P.tool('op_area_type_activity', {'arg': ''}, quiet=True)
    p = P.p
    p.pump(0.4)
    t, _ = P.tool('ui_tree')
    try:
        w = json.loads(t)['widgets']
    except (TypeError, ValueError, KeyError):
        w = []
    b = [x for x in w if x.get('kind') == 'button' and x.get('label') == which.capitalize()]
    check(bool(b), f'the AI Activity header shows {which.capitalize()}')
    if b:
        M.click(p, b[0]['x'] + b[0]['w'] // 2, b[0]['y'] + b[0]['h'] // 2)
    P.tool('op_area_type_viewport', {'arg': ''}, quiet=True)


def s_proposal():
    print('-- the proposal: begin, end, the user\'s answer, one undo step')
    P = One()
    try:
        check(P.status() == '"none"', f'proposal_status: none ({P.status()})')
        P.tool('propose_end', {}, 'propose_end with none open: the error', err=True)
        P.tool('propose_begin', {}, 'propose_begin without a title', err=False)
        check(P.status() == '"building"', f'proposal_status: building ({P.status()})')
        P.tool('propose_begin', {'title': 'again'}, 'propose_begin while one is open: the error', err=True)
        for n, a in (('undo', {}), ('redo', {}), ('run_operator', {'id': 'edit.undo'})):
            t, _ = P.tool(n, a)
            check(t is not None and 'wait' in t, f'{n} {a.get("id", "")} while a proposal is open: refused ({t!r})')
        P.key(28)
        check(P.status() == '"building"', f'Enter while the agent still works: nothing (still building: {P.status()})')
        P.key(1)
        P.key(1)
        check(P.status() == '"reverted"', f'Esc while building: reverted ({P.status()})')
        scen = ['enter', 'kpenter', 'esc', 'esc-building', 'banner-accept', 'banner-revert', 'header-accept', 'header-revert', 'failure', 'long-title']
        for r in range(RUNS):
            for s in scen:
                title = s if s != 'long-title' else 'T' * 150 + ' "quoted" ü'
                before = P.state()
                P.tool('propose_begin', {'title': title}, f'{s}: propose_begin', err=False)
                tree = f'P{r}{s[:3]}'
                cube = f'C{r}{s}'[:31]
                build(P, tree)
                P.tool('create_primitive', {'type': 'cube', 'name': cube}, quiet=True)
                if s == 'failure':
                    P.tool('run_operator', {'id': 'tree.link', 'arg': 'nope 1 2 3'}, f'{s}: a failing request inside it')
                    P.tool('script_eval', {'code': 'x = 1 +'}, f'{s}: a script error inside it', err=True)
                    t, _ = P.tool('describe_graph', {}, f'{s}: the trees while building')
                    check(t is not None and f'"{tree}"' in t, f'{s}: the tree there while building')
                if s != 'esc-building':
                    P.tool('propose_end', {}, f'{s}: propose_end', err=False)
                    P.tool('propose_end', {}, f'{s}: propose_end again (shown already)')
                if s in ('enter', 'failure', 'long-title'):
                    P.key(28)
                elif s == 'kpenter':
                    P.key(96)
                elif s in ('esc', 'esc-building'):
                    P.key(1)
                elif s.startswith('banner'):
                    banner_click(P, s.split('-')[1])
                else:
                    header_click(P, s.split('-')[1])
                after = P.state(f'{s}: the answer, the trees, the scene')
                reverted = 'esc' in s or 'revert' in s
                want = '"reverted"' if reverted else '"accepted"'
                check(P.status() == want, f'{s}: {want} ({P.status()})')
                objs = P.objects() or []
                if reverted:
                    check(cube not in objs and after[1:] == before[1:], f'{s}: reverted: the trees and the scene as before it')
                else:
                    check(cube in objs and f'"{tree}"' in (after[1] or ''), f'{s}: accepted: its tree and cube kept')
                P.tool('undo', {}, f'{s}: undo')
                if not reverted:
                    u = P.state()
                    check(cube not in (P.objects() or []) and u[1:] == before[1:], f'{s}: one undo takes the whole proposal away')
                P.tool('redo', {}, f'{s}: redo')
                check(P.state()[1:] == after[1:], f'{s}: redo: the trees and the scene as after the answer')
                P.tool('undo', {}, quiet=True)
                P.tool('redo', {}, quiet=True)
                P.key(28)
                check(P.status() == want, f'{s}: Enter after the answer: nothing (the console takes it)')
                P.key(1)   # (and Esc leaves the console: the next keys are the view's again)
        check(P.alive(), 'still running')
    finally:
        P.close()


# ---- the look -----------------------------------------------------------------------

def viewport_of(img):
    """The banner's rectangle (its background colour): x0, y0, x1, y1."""
    pts = [(x, y) for y in range(60, 220) for x in range(img.size[0]) if img.getpixel((x, y)) == (0x2b, 0x3a, 0x55)]
    if not pts:
        return None
    return min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)


def s_look():
    print('-- the banner: drawn while building and waiting, gone after the answer')
    P = One()
    S = os.environ.get('COPILOT_SHOTS')
    try:
        P.p.pump(0.6)
        check(viewport_of(P.p.image()) is None, 'no proposal: no banner')
        P.tool('propose_begin', {'title': 'A fence of cubes along the path'}, quiet=True)
        for phase in ('building', 'waiting'):
            if phase == 'waiting':
                P.tool('propose_end', {}, quiet=True)
            P.p.pump(0.6)
            im = P.p.image()
            if S:
                im.save(f'{S}/banner_{phase}.png')
            b = viewport_of(im)
            check(b is not None and b[2] - b[0] > 300 and b[3] - b[1] > 10, f'{phase}: the banner is drawn ({b})')
            if phase == 'waiting' and b:
                acc = sum(1 for y in range(b[1], b[3] + 1) for x in range(b[0], b[2] + 1) if im.getpixel((x, y)) == (0x3f, 0x8f, 0x5a))
                check(acc > 2000, f'waiting: the Accept button is drawn ({acc} px)')
        P.key(1)
        P.p.pump(0.6)
        check(viewport_of(P.p.image()) is None, 'reverted: the banner is gone (the view drawn again)')
    finally:
        P.close()


# ---- files --------------------------------------------------------------------------

def s_files():
    print('-- a proposal kept, then saved: the file reads back, opened again the same')
    P = One('files')
    try:
        P.tool('propose_begin', {'title': 'fence'}, quiet=True)
        build(P, 'Fence')
        P.tool('script_eval', {'code': 'm = modifier("Cube", "geometry")\nmodset("Cube", m, "tree", 1)'}, 'a Geometry Nodes modifier on the tree (script_eval)', err=False)
        P.tool('propose_end', {}, quiet=True)
        P.key(28)
        kept = P.state()
        P.tool('op_file_save_as', {'arg': '$HOME/cp.bee'}, quiet=True)
        import beefile
        f = os.path.join(P.p.home, 'cp.bee')
        try:
            tags = [t for t, _ in beefile.chunks(f)]
        except (OSError, AssertionError) as e:
            tags = []
            print('     ', e)
        check(b'NTRE' in tags and b'MODS' in tags, f'the proposal kept, saved: the file reads back, its node trees and modifiers in it ({len(tags)} chunks)')
        P.tool('undo', {}, 'undo after the save', quiet=True)
        P.tool('op_file_open', {'arg': '$HOME/cp.bee'}, quiet=True)
        again = P.state('opened again')
        check(again[1:] == kept[1:], 'opened again: the same trees and scene')
        check(again[0] in ('"none"', '"accepted"'), f'opened again: no proposal open ({again[0]})')
    finally:
        P.close()


def s_perm():
    print('-- read-only agents: they may look and propose, not build')
    P = One('read-only')
    try:
        P.tool('node_types', {}, 'read-only: node_types', err=False)
        P.tool('propose_begin', {'title': 'x'}, 'read-only: propose_begin (it changes nothing itself)', err=False)
        t, e = P.tool('run_operator', {'id': 'tree.new', 'arg': 'A'})
        check(e is True, f'read-only: tree.new refused ({t!r})')
        P.tool('propose_end', {}, 'read-only: propose_end', err=False)
        P.key(28)
        st = P.state('read-only: answered')
        check(st[0] == '"accepted"' and '"A"' not in (st[1] or ''), f'read-only: accepted with nothing in it ({st[0]})')
        P.tool('undo', {}, 'read-only: undo (nothing to undo)')
    finally:
        P.close()


# ---- fuzz ---------------------------------------------------------------------------

def s_fuzz():
    print(f'-- fuzz: {NFUZZ} random steps')
    rnd = random.Random(1234)
    p = M.Prog('files')
    try:
        names = ['T', 'Fence', '', 'é' * 40, 'x' * 300]
        bad = 0
        for k in range(NFUZZ):
            c = rnd.random()
            if c < 0.12:
                t, e, r = p.tool('propose_begin', {'title': rnd.choice(['a', '', 'ü' * 60, 'x' * 500, 5])})
            elif c < 0.22:
                t, e, r = p.tool('propose_end', {})
            elif c < 0.3:
                t, e, r = p.tool('proposal_status', {})
            elif c < 0.38:
                t, e, r = p.tool('describe_graph', rnd.choice([{}, {'tree': rnd.choice(names)}, {'tree': None}, {'tree': [1]}]))
            elif c < 0.6:
                op = rnd.choice(['tree.new', 'tree.node', 'tree.link', 'tree.node_set', 'tree.node_delete', 'tree.group'])
                arg = ' '.join(rnd.choice(['T', 'Fence', '1', '2', '3', '9', '-1', 'cube', 'output', 'line', '1e9', 'nan']) for _ in range(rnd.randint(0, 5)))
                t, e, r = p.tool('run_operator', {'id': op, 'arg': arg})
            elif c < 0.7:
                t, e, r = p.tool(rnd.choice(['undo', 'redo']), {})
            elif c < 0.9:
                p.f.enter(600, 300)
                p.f.key(rnd.choice([28, 96, 1, 1, 28, 44]))
                p.pump(0.05)
                t, r = 'key', 'key'
            else:
                t, e, r = p.tool('node_types', {})
            if r is None or (r != 'key' and M.wellformed(r)):
                bad += 1
            if not p.alive():
                break
        t, _, _ = p.tool('proposal_status', {})
        check(p.alive() and bad == 0, f'{NFUZZ} steps: still running, every request answered well formed ({bad} not)')
        check(t in ('"none"', '"building"', '"waiting for the user"', '"accepted"', '"reverted"'), f'the state is one of the five ({t})')
    finally:
        err = p.close() or ''   # (its stderr)
    check('panic' not in err and 'leak' not in err.lower(), 'no panic, no leak reported on stderr')


def main():
    t0 = time.time()
    try:
        for name, fn in [('json', s_json), ('proposal', s_proposal), ('look', s_look), ('files', s_files), ('perm', s_perm), ('fuzz', s_fuzz)]:
            if section(name):
                fn()
    finally:
        shutil.rmtree(M.T, True)
    print(f'copilot: {time.time() - t0:.0f} s, fails {len(FAILS)}')
    for f in FAILS:
        print('   ', f)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
