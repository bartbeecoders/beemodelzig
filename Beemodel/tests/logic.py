#!/usr/bin/env python3
"""Logic graphs (src/logic*.zig) and the node trees under them, run by
BeeModel alone. Most things are done two ways in the same build and must
agree: the operators through a BeeScript op() and through --op on the
command line (the same NTRE and MODS chunks), a play session through --play
and through a BeeScript (playstep, playinfo, logic, logicvar: the same bits).

  * s_ops: the walkthrough graphs made by logic.new, logic.node, logic.name,
    logic.attach, tree.link and tree.node_set; then words they do not
    understand, a graph full of names (30), of nodes (48), of trees (64),
    links that would loop or name nodes that are not there, a graph that is not
    a logic graph, an object that is not a mesh, tree.node_delete and
    tree.node_move: the same chunks both ways after every kind;
  * s_play: the walkthrough played (a door that opens near the player, coins
    that spin and are picked up, a score counted by messages, a timer, a
    branch, Get Property, E spawning a coin, a ball pushed at Begin Play, a
    platform moved by Start + sin(Time) x 2 the player rides): the player, the
    objects, the graphs' counters and the score's variables every tenth of a
    second; kept and discarded; saved and opened again;
  * s_same: the same session twice: the same scene;
  * s_storm: a message storm cut off at the step budget (4096 nodes);
  * s_nodes: every node type and every choice (18 math operations, 9 infos,
    the properties, keys pressed / released / held, overlaps entering /
    leaving / inside of the player and of objects, hits, one-shot and repeating
    timers, messages to one object, visibility, Set Strength on a force field,
    the Field node) into variables;
  * s_random: random graphs (types, values, names, links) made and played;
  * s_damaged: damaged NTRE and MODS chunks (cut short, counts past the
    records, node counts past 48, links and types and names that point
    nowhere, NaN values) opened and played: no crash, both routes agree;
  * s_files: NTRE and MODS kept by open -> save;
  * s_undo: the logic operators undone and redone (the trees as they were);
  * s_fuzz: a fuzz of the operators' words (no crash).

    python3 tests/logic.py BIN [runs=6] [seed]

BEE_CPU (default 12) pins BeeModel; LOGIC_ONLY=s_ops,s_play ... runs some.
"""
import os, random, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import playlib as L  # noqa: E402
import beefile  # noqa: E402

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('LOGIC_ONLY', '').split(',') if x]
T = L.T
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(sec):
    return not ONLY or sec in ONLY


GEO = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 20)
add("cube", "Door", 0, 1.25, -5)
scale("Door", 1, 1.25, 0.1)
key("Door:y", 1, 1.25, "linear")
key("Door:y", 25, 3.6, "linear")
select("Door")
op("anim.action", "DoorOpen")
unkey("Door:y", 1)
unkey("Door:y", 25)
add("cube", "Coin", 3, 0.5, 0)
scale("Coin", 0.2)
add("cube", "Score", 0, 5, 5)
scale("Score", 0.2)
add("cube", "Ball", -3, 0.5, 3)
scale("Ball", 0.5)
select("Ball")
op("rigid.add", "active box")
select("Floor")
op("rigid.add", "passive box")
add("cube", "Lift", -4, 0.25, -3)
scale("Lift", 1, 0.25, 1)
op("field.add_attractor")
select()
'''

# the walkthrough graphs, as operators
GRAPHS = [
    ('logic.new', 'DoorLogic'), ('logic.node', 'DoorLogic overlap 0 0 1.5'), ('logic.node', 'DoorLogic play_action'),
    ('logic.name', 'DoorLogic 2 4 DoorOpen'), ('tree.link', 'DoorLogic 1 2 1'), ('logic.attach', 'DoorLogic Door'),
    ('logic.new', 'CoinLogic'), ('logic.node', 'CoinLogic overlap 0 0 0.2'), ('logic.node', 'CoinLogic destroy'), ('logic.node', 'CoinLogic send'),
    ('logic.name', 'CoinLogic 3 4 picked'), ('tree.link', 'CoinLogic 1 2 1'), ('tree.link', 'CoinLogic 2 3 1'), ('logic.node', 'CoinLogic tick'),
    ('logic.node', 'CoinLogic rotate'), ('tree.node_set', 'CoinLogic 5 2 0 1 0'), ('tree.link', 'CoinLogic 4 5 1'), ('logic.attach', 'CoinLogic Coin'),
    ('logic.new', 'ScoreLogic'), ('logic.node', 'ScoreLogic message'), ('logic.name', 'ScoreLogic 1 4 picked'), ('logic.node', 'ScoreLogic set_variable 0 1'),
    ('tree.link', 'ScoreLogic 1 2 1'), ('tree.link', 'ScoreLogic 1:1 2 2'), ('logic.node', 'ScoreLogic timer 0.5 0'), ('logic.node', 'ScoreLogic set_variable 1'),
    ('tree.node_set', 'ScoreLogic 4 2 7 7 7'), ('tree.link', 'ScoreLogic 3 4 1'), ('logic.node', 'ScoreLogic key 18 0'), ('logic.node', 'ScoreLogic spawn'),
    ('logic.name', 'ScoreLogic 6 4 Coin'), ('tree.node_set', 'ScoreLogic 6 2 3 -5 -2'), ('tree.link', 'ScoreLogic 5 6 1'), ('logic.node', 'ScoreLogic tick'),
    ('logic.node', 'ScoreLogic branch'), ('logic.node', 'ScoreLogic variable 0'), ('logic.node', 'ScoreLogic math 8'), ('tree.node_set', 'ScoreLogic 10 2 0.5'),
    ('tree.link', 'ScoreLogic 9 10 1'), ('tree.link', 'ScoreLogic 10 8 2'), ('tree.link', 'ScoreLogic 7 8 1'), ('logic.node', 'ScoreLogic set_variable 2'),
    ('tree.node_set', 'ScoreLogic 11 2 1'), ('tree.link', 'ScoreLogic 8:0 11 1'), ('logic.node', 'ScoreLogic set_variable 3'), ('logic.node', 'ScoreLogic get_property'),
    ('logic.name', 'ScoreLogic 13 4 x'), ('logic.name', 'ScoreLogic 13 5 Coin'), ('tree.link', 'ScoreLogic 13 12 2'), ('tree.link', 'ScoreLogic 7 12 1'),
    ('logic.attach', 'ScoreLogic Score'),
    ('logic.new', 'BallLogic'), ('logic.node', 'BallLogic begin'), ('logic.node', 'BallLogic impulse'), ('tree.node_set', 'BallLogic 2 2 0 0 -4'),
    ('tree.link', 'BallLogic 1 2 1'), ('logic.attach', 'BallLogic Ball'),
    ('logic.new', 'LiftLogic'), ('logic.node', 'LiftLogic tick'), ('logic.node', 'LiftLogic move 1'), ('logic.node', 'LiftLogic info 4'),
    ('logic.node', 'LiftLogic info 0'), ('logic.node', 'LiftLogic math 6'), ('logic.node', 'LiftLogic math 17'), ('logic.node', 'LiftLogic math 0'),
    ('tree.link', 'LiftLogic 1:0 2 1'), ('tree.link', 'LiftLogic 4 5 1'), ('tree.node_set', 'LiftLogic 6 1 2 0 0'), ('tree.link', 'LiftLogic 5 6 2'),
    ('tree.link', 'LiftLogic 3 7 1'), ('tree.link', 'LiftLogic 6 7 2'), ('tree.link', 'LiftLogic 7 2 2'), ('logic.attach', 'LiftLogic Lift'),
]


def make(name, code):
    path = f'{T}/{name}.bee'
    if os.path.exists(path):
        os.remove(path)
    out, err = L.run_script(BIN, code + f'\nop("file.save", "{path}")\n')
    if not os.path.exists(path):
        print(out[-500:], err[-500:])
    return path


def ops_code(ops):
    return '\n'.join(f'op("{o}", "{L.esc(a)}")' for o, a in ops)


def ops_args(ops):
    out = []
    for o, a in ops:
        out += ['--op', f'{o} {a}'.strip()]
    return out


def both_chunks(base, ops, tags=(b'NTRE', b'MODS')):
    """The ops on the scene in `base`, once by a BeeScript's op() and once by
    --op: the chunks that differ (['missing'] when a file was not saved)."""
    po, pp = f'{T}/co.bee', f'{T}/cp.bee'
    for p in (po, pp):
        if os.path.exists(p):
            os.remove(p)
    L.run_script(BIN, f'op("file.open", "{base}")\n' + ops_code(ops) + f'\nop("file.save", "{po}")\n')
    L.run_port(BIN, ['--op', f'file.open {base}'] + ops_args(ops) + ['--op', f'file.save {pp}'])
    if not os.path.exists(po) or not os.path.exists(pp):
        return ['missing']
    return [t.decode() for t in tags if beefile.chunk(po, t) != beefile.chunk(pp, t)]


def run(actions, what, pre=None):
    oa, pa, d, r = L.session(BIN, BIN, actions, prefix=pre)
    check(d is None and len(oa) > 0, f'{what}: {len(oa)} moments, --play and a BeeScript give the same bits' + (f' ({d})' if d else ''))
    return {t: v for t, v in pa}, d


# ---- s_ops ----------------------------------------------------------------------------------------

def s_ops(geo):
    print('-- the operators, by a script and by --op: NTRE and MODS byte for byte --')
    d = both_chunks(geo, GRAPHS)
    check(d == [], f'the walkthrough\'s five graphs ({len(GRAPHS)} operators){": apart " + str(d) if d else ""}')
    bad = [
        ('logic.new', ''), ('logic.new', 'abcdefghijklmnopqrstuvwxyz0123456789'), ('logic.node', ''), ('logic.node', 'Nope tick'), ('logic.node', 'Logic'),
        ('logic.node', 'Logic warp'), ('logic.node', 'Logic tick 1 2 3 4 5 6'), ('logic.node', 'Logic math 3 x 7'), ('logic.node', 'Logic set_strength'),
        ('logic.node', 'Logic field'), ('logic.name', 'Logic'), ('logic.name', 'Logic 1'), ('logic.name', 'Logic 1 3 a'), ('logic.name', 'Logic 1 8 a'),
        ('logic.name', 'Logic 9 4 a'), ('logic.name', 'Logic 0 4 a'), ('logic.name', 'Logic 1 4 sixteen_chars_ab'), ('logic.name', 'Logic 1 4 fifteen_chars_a'),
        ('logic.name', 'Logic 1 4'), ('tree.new', 'Geo'), ('logic.node', 'Geo tick'), ('logic.attach', 'Geo Floor'), ('logic.attach', 'Logic Camera'),
        ('logic.attach', 'Logic Nobody'), ('logic.attach', 'Logic'), ('tree.link', 'Logic'), ('tree.link', 'Logic 1 1 1'), ('tree.link', 'Logic 1 2 0'),
        ('tree.link', 'Logic 1 2 4'), ('tree.link', 'Logic 1:256 2 1'), ('tree.link', 'Logic 1:3 2 1'), ('tree.link', 'Logic 2 1 1'), ('tree.link', 'Logic 1 99 1'),
        ('tree.link', 'Logic x 2 1'), ('tree.link', 'Logic -1 2 1'), ('tree.node_set', 'Logic 1 2'), ('tree.node_set', 'Logic 1 2 5 6'), ('tree.node_set', 'Logic 1 9 5'),
        ('tree.node_set', 'Logic 1 0 5'), ('tree.node_set', 'Logic 99 4 1'), ('tree.node_set', 'Logic 2 5 1e30'), ('tree.node_move', 'Logic 1 0 0'),
        ('tree.node_move', 'Logic 1 -40000 70000'), ('tree.node_move', 'Logic 7 1 1'), ('tree.node_delete', 'Logic 1'), ('tree.node_delete', 'Logic 50'),
        ('logic.node', 'Logic shatter'), ('tree.link', 'Logic 1 2 2'), ('tree.node_delete', 'Logic 1'),
    ]
    d = both_chunks(geo, [('logic.new', 'Logic'), ('logic.node', 'Logic tick'), ('logic.node', 'Logic move')] + bad)
    check(d == [], f'{len(bad)} operators with words they cannot use, links that loop or point nowhere, a geometry tree, a camera: the same chunks both ways{": apart " + str(d) if d else ""}')
    names = [('logic.new', 'N')] + [('logic.node', 'N send')] * 16 + [('logic.name', f'N {k // 2 + 1} {4 + k % 2} name{k}') for k in range(32)]
    names += [('logic.name', 'N 3 4 name1'), ('logic.name', 'N 2 5'), ('logic.name', 'N 5 4 again')]
    d = both_chunks(geo, names)
    check(d == [], f'a graph full of names (30): the 31st and 32nd refused, a name used again, one taken off{": apart " + str(d) if d else ""}')
    full = [('logic.new', 'F')] + [('logic.node', f'F math {k % 18} {k}') for k in range(50)] + [('tree.link', f'F {k} {k + 1} 1') for k in range(1, 48)]
    full += [('tree.link', 'F 48 1 2'), ('tree.node_delete', 'F 20'), ('tree.link', 'F 47 1 2'), ('tree.node_move', 'F 5 100 -50'), ('tree.link', 'F 45 21 3'), ('tree.link', 'F 18 2 3')]
    d = both_chunks(geo, full)
    check(d == [], f'48 nodes in a chain, the 49th refused, the loop refused, a node deleted (the links one down){": apart " + str(d) if d else ""}')
    trees = [('logic.new', 'X')] * 66 + [('tree.new', '')] * 2 + [('logic.node', 'X.063 tick')]
    d = both_chunks(geo, trees, (b'NTRE',))
    check(d == [], f'64 trees at most (X, X.001 ... X.063){": apart " + str(d) if d else ""}')


# ---- s_play ---------------------------------------------------------------------------------------

def s_play(level):
    print('-- the walkthrough played --')
    objs = ['o:Door', 'o:Coin', 'o:Ball', 'o:Lift']
    vs = [f'v:Score:{k}:{c}' for k in range(4) for c in range(3)]
    a = [('op', 'file.open', level), ('op', 'play.start', 'walk 3 1.8 3'), ('step', 0.6), ('dump', 'Started', ['p', 'l'] + vs + objs), ('look', 0, 0)]
    for i in range(12):
        a += [('step', 0.1, 1, 0, 0), ('dump', f'C{i}', ['p', 'l'] + vs + objs)]
    a += [('key', 18, 1), ('step', 0.1), ('key', 18, 0), ('dump', 'Spawned', ['p', 'l', 'o:Coin.001'] + vs), ('step', 0.5), ('dump', 'Spins', ['l', 'o:Coin.001'])]
    a += [('op', 'play.stop', 'keep'), ('dump', 'Kept', ['l', 'v:Score:0:0', 'o:Coin.001', 'o:Coin'])]
    p, _ = run(a, 'walking into the coin picks it up (destroyed, a message counts it, a branch follows); E spawns a coin that spins; kept')
    if p:
        s, c = p.get('Started'), p.get('C11')
        check(s and s[19:21] == [1, 5] if s else False, f'play begins: {s and s[20]:.0f} graphs run')
        check(c and c[28 + 0] == 1 if c else False, f'the score counted the coin ({c and c[28]})')
    a = [('op', 'file.open', level), ('op', 'play.start', 'walk 0 1.8 0'), ('step', 0.5), ('look', 0, 0)]
    for i in range(20):
        a += [('step', 0.1, 1, 0, 0), ('dump', f'D{i}', ['p', 'l', 'o:Door', 'o:Ball'])]
    a += [('op', 'play.stop', 'discard'), ('dump', 'Discarded', ['l', 'o:Door', 'o:Ball']), ('op', 'play.start', 'walk -4 2.5 -3')]
    for i in range(16):
        a += [('step', 0.1), ('dump', f'L{i}', ['p', 'o:Lift'])]
    p, _ = run(a, 'the door opens near the player (On Overlap -> Play Action), Begin Play pushed the ball; discarded; the platform moves (Start + sin(Time) x 2) and carries the player')
    if p:
        dd, ds = p.get('D19'), p.get('Discarded')
        check(dd and dd[28 + 1] > 3 if dd else False, f'the door went up ({dd and dd[29]:.2f})')
        check(ds and abs(ds[9 + 1] - 1.25) < 1e-6 and abs(ds[19 + 2] - 3) < 1e-6 if ds else False, 'discarded: the door and the ball as they were')
    # saved during play's keep and opened again: the same graphs run again
    a = [('op', 'file.open', level), ('op', 'play.start', 'walk 3 1.8 3'), ('step', 1.0, 0, 1, 0), ('op', 'play.stop', 'keep'), ('save', f'{T}/kept.bee'),
         ('op', 'file.open', f'{T}/kept.bee'), ('op', 'play.start', 'fly 0 3 6'), ('step', 0.5), ('dump', 'Again', ['p', 'l'] + vs + objs)]
    run(a, 'kept, saved, opened again: its graphs run again')


# ---- s_same, s_storm ----------------------------------------------------------------------------------

def s_same(level):
    print('-- deterministic --')
    a = [('op', 'file.open', level), ('op', 'play.start', 'walk 2 1.8 4'), ('look', 30, 0), ('step', 1.5, 1, 0, 0), ('key', 18, 1), ('step', 1), ('key', 18, 0),
         ('step', 1, 1, 1, 0), ('dump', 'State', ['p', 'l', 'o:Ball', 'o:Lift', 'o:Coin', 'o:Coin.001'])]
    p1, _ = run(a, 'a session')
    p2, _ = run(a, 'the same session again')
    check(bool(p1) and p1 == p2, 'the same scene both times')


def s_storm(geo):
    print('-- a message storm --')
    ops = [('logic.new', 'Storm'), ('logic.node', 'Storm message'), ('logic.name', 'Storm 1 4 ping'), ('logic.node', 'Storm send'), ('logic.name', 'Storm 2 4 ping'),
           ('tree.link', 'Storm 1 2 1'), ('logic.node', 'Storm begin'), ('logic.node', 'Storm send'), ('logic.name', 'Storm 4 4 ping'), ('tree.link', 'Storm 3 4 1'),
           ('logic.node', 'Storm set_variable 0 1'), ('tree.node_set', 'Storm 5 2 1'), ('tree.link', 'Storm 1 5 1')]
    for i in range(30):
        ops += [('logic.node', 'Storm set_variable 1 1'), ('tree.link', f'Storm 1 {6 + i} 1')]
    ops.append(('logic.attach', 'Storm Coin'))
    a = [('op', 'file.open', geo)] + [('op', o, x) for o, x in ops] + [('op', 'play.start', 'fly 0 3 6')]
    for i in range(6):
        a += [('step', 0.05), ('dump', f'S{i}', ['p', 'l', 'v:Coin:0:0', 'v:Coin:1:0'])]
    p, _ = run(a, 'every step cut off at 4096 nodes, play goes on')
    if p:
        s = p.get('S5')
        check(s and s[19 + 6] > 0 and s[19 + 7] <= 4096 if s else False, f'steps past the budget: {s and s[25]:.0f}, nodes the last step: {s and s[26]:.0f}')


# ---- s_nodes ----------------------------------------------------------------------------------------

def graph(name, nodes, links, sets=(), names=(), attach='Coin'):
    """ops for a graph: nodes as 'type values', links (from[:out], to, input), sets (node, slot, xyz), names (node, slot, text)."""
    out = [('logic.new', name)]
    out += [('logic.node', f'{name} {n}') for n in nodes]
    out += [('logic.name', f'{name} {n} {s} {t}') for n, s, t in names]
    out += [('tree.node_set', f'{name} {n} {s} {v}') for n, s, v in sets]
    out += [('tree.link', f'{name} {f} {t} {i}') for f, t, i in links]
    out.append(('logic.attach', f'{name} {attach}'))
    return out


def s_nodes(geo):
    print('-- every node type and choice --')
    ops = []
    # math: Tick -> 18 Set Variable (one per operation, variables 0..7 of 3 objects)
    nodes, links, sets = ['tick'], [], []
    for op_ in range(18):
        nodes += [f'math {op_}', f'set_variable {op_ % 8} 1']
        m, sv = 2 + op_ * 2, 3 + op_ * 2
        sets += [(m, 1, f'{0.3 * op_ - 2} {1.5 - op_ * 0.2} {op_ * 0.7 - 5}'), (m, 2, f'{op_ * 0.1 - 0.9} {2 - op_ * 0.25} 0.5')]
        links += [(1, sv, 1), (m, sv, 2)]
    nodes += ['info 0', 'math 2', 'math 6']        # sin(time * a)
    sets += [(39, 2, '3.7 -1.3 50')]
    links += [(38, 39, 1), (39, 40, 1), (40, 3, 2)]
    ops += graph('Maths', nodes, links, sets, attach='Coin')
    # info: Tick -> 9 Set Variable from the infos
    nodes, links = ['tick'], []
    for k in range(9):
        nodes += [f'info {k}', f'set_variable {k % 8} {1 if k < 8 else 0}']
        links += [(1, 3 + 2 * k, 1), (2 + 2 * k, 3 + 2 * k, 2)]
    ops += graph('Infos', nodes, links, attach='Score')
    # properties, visibility, timers, keys, overlaps, hits, messages, set strength, field
    nodes = ['timer 0.3 1', 'set_property', 'get_property', 'set_variable 0 1', 'timer 0.25 0', 'visibility', 'key 30 0', 'key 30 1', 'key 30 2',
             'set_variable 1 1', 'set_variable 2 1', 'set_variable 3 1', 'overlap 0 0 0.5', 'overlap 0 1 0.5', 'overlap 0 2 0.5', 'set_variable 4 1',
             'set_variable 5 1', 'set_variable 6 1', 'hit', 'set_variable 7 1', 'send', 'set_strength', 'field', 'set_variable 0 0', 'overlap 0 0 0',
             'branch', 'get_property', 'math 0']
    names = [(2, 4, 'z'), (2, 5, 'Door'), (3, 4, 'z'), (3, 5, 'Door'), (6, 4, 'Door'), (13, 4, 'Ball'), (21, 4, 'ping'), (21, 5, 'Score'), (22, 4, 'Attractor'),
             (25, 4, 'Lift'), (27, 4, 'visible'), (27, 5, 'Lift')]
    sets = [(2, 2, '0.1'), (6, 2, '0'), (10, 2, '1 0 0'), (11, 2, '0 1 0'), (12, 2, '0 0 1'), (16, 2, '1'), (17, 2, '1'), (18, 2, '1'), (20, 2, '1'), (22, 2, '-3'),
            (23, 1, '1 2 3'), (21, 2, '5')]
    links = [(1, 2, 1), (3, 28, 1), (1, 4, 1), (28, 4, 2), (5, 6, 1), (7, 10, 1), (8, 11, 1), (9, 12, 1), (13, 16, 1), (14, 17, 1), (15, 18, 1), (19, 20, 1),
             (1, 21, 1), (1, 22, 1), (1, 26, 1), (27, 26, 2), (26, 24, 1), (23, 24, 2), (25, 24, 1)]
    ops += graph('Props', nodes, links, sets, names, attach='Ball')
    # infinities, NaN (inf - inf) into min and max both ways, a divisor under 1e-4
    nodes = ['tick', 'math 2', 'math 1', 'math 4', 'math 4', 'math 5', 'math 5', 'math 3', 'set_variable 0', 'set_variable 1', 'set_variable 2',
             'set_variable 3', 'set_variable 4', 'set_variable 5']
    sets = [(2, 1, '1e30 -1e30 1e30'), (2, 2, '1e30 1e30 2'), (4, 2, '1 2 3'), (5, 1, '1 2 3'), (6, 2, '1 2 3'), (7, 1, '1 2 3'), (8, 1, '1 -2 3'),
            (8, 2, '0.00005 -0.00009 0.0001')]
    links = [(2, 3, 1), (2, 3, 2), (3, 4, 1), (3, 5, 2), (3, 6, 1), (3, 7, 2)] + [(1, 9 + k, 1) for k in range(6)] + [(4 + k, 9 + k, 2) for k in range(5)] + [(2, 14, 2)]
    ops += graph('Edge', nodes, links, sets, attach='Door')
    # the player on the lift and off it: enter, inside, leave; a message to the Score not for it
    nodes = ['overlap 0 0 0.3', 'overlap 0 1 0.3', 'overlap 0 2 0.3', 'set_variable 0 1', 'set_variable 1 1', 'set_variable 2 1', 'message', 'set_variable 3 1',
             'hit', 'set_variable 4 1']
    sets = [(4, 2, '1'), (5, 2, '1'), (6, 2, '1'), (8, 2, '1'), (10, 2, '1')]
    ops += graph('Gate', nodes, [(1, 4, 1), (2, 5, 1), (3, 6, 1), (7, 8, 1), (9, 10, 1)], sets, [(7, 4, 'ping')], attach='Lift')
    ops += graph('Msgs', ['message', 'set_variable 0 1', 'message', 'set_variable 1 1'], [(1, 2, 1), (1, 2, 2), (3, 4, 1)], (), [(1, 4, 'ping'), (3, 4, 'nobody')], attach='Score')
    base = f'{T}/nodes.bee'
    if os.path.exists(base):
        os.remove(base)
    L.run_script(BIN, f'op("file.open", "{geo}")\n' + ops_code(ops) + f'\nop("file.save", "{base}")\n')
    vs = [f'v:{o}:{k}:{c}' for o in ('Coin', 'Score', 'Ball') for k in range(8) for c in range(3)]
    a = [('op', 'file.open', base), ('op', 'play.start', 'walk -4 1.8 0')]
    keys = [(30, 1), None, (30, 0), None, None, (30, 1), (30, 0), (30, 1), None, None, (30, 0)]
    for i in range(10):
        if i < len(keys) and keys[i]:
            a.append(('key',) + keys[i])
        a += [('step', 0.1, 1 if i > 3 else 0, 0, 0), ('dump', f'N{i}', ['p', 'l', 'o:Door', 'o:Lift', 'o:Attractor'] + vs[:24])]
        a += [('dump', f'M{i}', vs[24:] + [f'v:Door:{k}:{c}' for k in range(6) for c in range(3)])]
    a += [('op', 'play.stop', ''), ('op', 'play.start', 'walk -4 2.5 -3'), ('look', 0, 0)]
    for i in range(14):
        a += [('step', 0.1, 1 if i > 3 else 0, 0, 0), ('dump', f'G{i}', ['p'] + [f'v:Lift:{k}:0' for k in range(5)] + ['v:Score:0:0'])]
    p, _ = run(a, 'math, info, properties, visibility, timers, keys, overlaps, hits, messages, Set Strength, Field')
    if p and p.get('G13'):
        g = p['G13'][19:25]
        check(g[0] == 1 and g[1] == 1 and g[2] > 3 and g[3] == 0 and g[4] == 1 and g[5] > 0,
              f'on the lift and off it: entered {g[0]}, left {g[1]}, inside {g[2]} steps, hit once ({g[4]}); the Score\'s message not the lift\'s ({g[3]}, {g[5]})')
    if p:
        n9, m9 = p.get('N9'), p.get('M9')
        vals = [x for x in (n9 or [])[28 + 30:] + (m9 or []) if x is not None]
        nz = len({round(x, 6) for x in vals if x != 0})
        print(f'       last moment: {nz} different non-zero variables, Door z {n9 and n9[28 + 2]}, Lift hidden {n9 and n9[28 + 19]}')
        check(nz > 30, f'the graphs did something: {nz} different non-zero values in the variables')


def s_mods(geo):
    print('-- a Logic modifier with an Array: the overlap box is the array\'s --')
    a = [('op', 'file.open', geo), ('sel', 'Coin'), ('op', 'object.modifier_add', 'array'), ('op', 'object.modifier_set', '0 count 12')]
    a += [('op', o, x) for o, x in graph('Wide', ['overlap 0 0 0.1', 'set_variable 0 1', 'tick', 'info 2', 'set_variable 1'], [(1, 2, 1), (3, 5, 1), (4, 5, 2)],
                                          [(2, 2, '1')], attach='Coin')]
    a += [('op', 'object.modifier_add', 'subsurf'), ('op', 'play.start', 'walk 6 1.8 2'), ('look', 0, 0)]
    for i in range(12):
        a += [('step', 0.1, 1, 0, 0), ('dump', f'W{i}', ['p', 'l', 'v:Coin:0:0', 'v:Coin:1:0'])]
    p, _ = run(a, 'the player walks into the array\'s copies, not the coin\'s own box')
    if p and p.get('W11'):
        check(p['W11'][28] == 1, f'it entered the array\'s box ({p["W11"][28]})')


# ---- s_random -------------------------------------------------------------------------------------

TYPES = ['begin', 'tick', 'key', 'overlap', 'hit', 'timer', 'message', 'move', 'rotate', 'set_property', 'spawn', 'destroy', 'play_action', 'impulse',
         'visibility', 'send', 'set_variable', 'branch', 'variable', 'math', 'info', 'get_property', 'shatter', 'set_strength', 'field']
NAMES = ['Door', 'Coin', 'Ball', 'Lift', 'Score', 'Attractor', 'x', 'y', 'rz', 'sx', 'visible', 'ping', 'DoorOpen', 'Nobody', 'Floor']


def random_graph(rng, name, attach):
    n = rng.randrange(3, 16)
    nodes = []
    for _ in range(n):
        t = rng.choice(TYPES[:2] * 3 + TYPES)
        vals = ' '.join(str(rng.choice([0, 1, 2, 3, 5, 8, 17, 18, 30, 0.5, -1, 0.25, 2.5])) for _ in range(rng.randrange(0, 4)))
        nodes.append(f'{t} {vals}'.strip())
    links = [(f'{rng.randrange(1, n + 1)}:{rng.randrange(0, 3)}', rng.randrange(1, n + 1), rng.randrange(1, 4)) for _ in range(rng.randrange(n, 3 * n))]
    sets = [(rng.randrange(1, n + 1), rng.randrange(1, 4), ' '.join(f'{rng.uniform(-3, 3):.3f}' for _ in range(rng.choice([1, 3])))) for _ in range(rng.randrange(0, n))]
    names = [(rng.randrange(1, n + 1), rng.randrange(4, 8), rng.choice(NAMES)) for _ in range(rng.randrange(0, n))]
    return graph(name, nodes, links, sets, names, attach)


def s_random(geo, rng):
    print(f'-- random graphs (seed {SEED}) --')
    bad = 0
    for run_ in range(RUNS):
        ops = []
        for g in range(rng.randrange(1, 4)):
            ops += random_graph(rng, f'R{g}', rng.choice(['Coin', 'Score', 'Ball', 'Lift', 'Door']))
        base = f'{T}/rnd.bee'
        if os.path.exists(base):
            os.remove(base)
        L.run_script(BIN, f'op("file.open", "{geo}")\n' + ops_code(ops) + f'\nop("file.save", "{base}")\n')
        d = both_chunks(geo, ops)
        a = [('op', 'file.open', base), ('op', 'play.start', f'walk {rng.uniform(-5, 5):.2f} 1.8 {rng.uniform(-5, 5):.2f}')]
        for i in range(12):
            if rng.random() < 0.3:
                a.append(('key', rng.choice([18, 30, 17, 57]), rng.choice([0, 1])))
            a += [('step', rng.choice([0.05, 0.1, 0.2]), rng.choice([0, 1]), rng.choice([-1, 0, 1]), 0), ('dump', f'R{i}', ['p', 'l', 'o:Door', 'o:Coin', 'o:Ball', 'o:Lift', 'o:Score'])]
            a += [('dump', f'V{i}', [f'v:{o}:{k}:0' for o in ('Coin', 'Score', 'Ball') for k in range(8)])]
        oa, pa, dd, _ = L.session(BIN, BIN, a)
        if d or dd:
            bad += 1
            print('      ', run_, d, dd)
    check(bad == 0, f'{RUNS} random scenes of graphs: the same chunks both ways, played the same bits both ways')


# ---- s_damaged ----------------------------------------------------------------------------------------

def write_bee(path, chs):
    with open(path, 'wb') as f:
        f.write(b'BEEM' + struct.pack('<I', 1))
        for t, b in chs:
            f.write(t + struct.pack('<I', len(b)) + b)


def s_damaged(level, rng):
    print('-- damaged NTRE and MODS chunks --')
    chs = beefile.chunks(level)
    ntre = beefile.chunk(level, b'NTRE')
    n = struct.unpack_from('<I', ntre)[0]
    cases = {
        'cut to 3 bytes': ntre[:3], 'cut in its records': ntre[:4 + 4096 * 2 + 100], 'a count past its records': struct.pack('<I', n + 5) + ntre[4:],
        'a count of 1000': struct.pack('<I', 1000) + ntre[4:], 'no records': struct.pack('<I', 0), 'empty': b'',
    }
    recs = bytearray(ntre)
    for k in range(n):
        o = 4 + k * 4096
        recs[o + 128:o + 132] = struct.pack('<I', 49 + k)              # node counts past 48
    cases['node counts past 48'] = bytes(recs)
    for name, mut in (('links to nodes not there', lambda r, o: r.__setitem__(slice(o + 4, o + 6), struct.pack('<H', rng.randrange(1, 65535)))),
                      ('types past the last', lambda r, o: r.__setitem__(slice(o, o + 4), struct.pack('<I', rng.choice([0, 26, 99, 0xffffffff])))),
                      ('NaN and huge values', lambda r, o: r.__setitem__(slice(o + 52, o + 68), struct.pack('<4f', float('nan'), 1e30, -1e30, float('inf')))),
                      ('names without an end', lambda r, o: None)):
        r = bytearray(ntre)
        for k in range(n):
            base = 4 + k * 4096
            nn = struct.unpack_from('<I', r, base + 128)[0]
            for j in range(min(nn, 48)):
                if rng.random() < 0.5:
                    mut(r, base + 160 + j * 72)
            if name == 'names without an end':
                r[base + 3616:base + 4096] = bytes(rng.randrange(65, 90) for _ in range(480))
                r[base:base + 32] = bytes(rng.randrange(65, 90) for _ in range(32))
        cases[name] = bytes(r)
    mods = beefile.chunk(level, b'MODS')
    bad = []
    for name, data in cases.items():
        path = f'{T}/dmg.bee'
        write_bee(path, [(t, data if t == b'NTRE' else b) for t, b in chs])
        a = [('op', 'file.open', path), ('op', 'play.start', 'walk 3 1.8 3'), ('look', 0, 0)]
        for i in range(6):
            a += [('step', 0.1, 1, 0, 0), ('dump', f'D{i}', ['p', 'l', 'o:Door', 'o:Coin', 'o:Ball', 'o:Lift'])]
        oa, pa, d, _ = L.session(BIN, BIN, a)
        if d:
            bad.append((name, d))
    # MODS: a Logic modifier naming trees not there, or not logic
    m = bytearray(mods)
    for v in (0.0, -1.0, 6.0, 64.0, 1e9, float('nan')):
        pass
    for k in range(0, len(m) - 4, 4):
        if struct.unpack_from('<I', m, k)[0] == 12 and k + 8 <= len(m) - 4:
            m[k + 8:k + 12] = struct.pack('<f', rng.choice([0.0, -1.0, 6.0, 64.0, 1e9, float('nan'), 2.0]))
    path = f'{T}/dmg.bee'
    write_bee(path, [(t, bytes(m) if t == b'MODS' else b) for t, b in chs])
    a = [('op', 'file.open', path), ('op', 'play.start', 'walk 3 1.8 3')] + [x for i in range(4) for x in (('step', 0.1, 1, 0, 0), ('dump', f'M{i}', ['p', 'l', 'o:Door', 'o:Ball']))]
    oa, pa, d, _ = L.session(BIN, BIN, a)
    if d:
        bad.append(('Logic modifiers naming trees not there', d))
    for b in bad:
        print('      ', b)
    check(not bad, f'{len(cases) + 1} damaged files opened and played: no crash, both routes the same')


# ---- s_files, s_undo ----------------------------------------------------------------------------------

def s_files(level, geo):
    print('-- NTRE and MODS kept by open -> save --')
    pp, po = f'{T}/p1.bee', f'{T}/o1.bee'
    for p in (pp, po):
        if os.path.exists(p):
            os.remove(p)
    L.run_port(BIN, ['--op', f'file.open {geo}'] + ops_args(GRAPHS) + ['--op', f'file.save {pp}'])
    L.run_script(BIN, f'op("file.open", "{pp}")\nop("file.save", "{po}")\n')
    ok = os.path.exists(pp) and os.path.exists(po)
    check(ok and beefile.chunk(pp, b'NTRE') == beefile.chunk(po, b'NTRE') and beefile.chunk(pp, b'MODS') == beefile.chunk(po, b'MODS'),
          'graphs made by --op, opened by a script and saved: the same NTRE and MODS')
    pq = f'{T}/p2.bee'
    L.run_port(BIN, ['--op', f'file.open {level}', '--op', f'file.save {pq}'])
    check(os.path.exists(pq) and beefile.chunk(pq, b'NTRE') == beefile.chunk(level, b'NTRE'), 'graphs made by a script, opened by --op and saved: the same NTRE')


def s_undo(geo):
    print('-- undo and redo --')
    a = ['--op', f'file.open {geo}', '--op', 'logic.new G', '--op', 'logic.node G tick', '--op', f'file.save {T}/u1.bee', '--op', 'logic.node G move',
         '--op', 'tree.link G 1 2 1', '--op', f'file.save {T}/u6.bee', '--op', 'logic.name G 2 4 Door', '--op', f'file.save {T}/u2.bee',
         '--op', 'edit.undo', '--op', 'edit.undo', '--op', 'edit.undo', '--op', f'file.save {T}/u3.bee', '--op', 'edit.redo', '--op', 'edit.redo',
         '--op', 'edit.redo', '--op', f'file.save {T}/u4.bee', '--op', 'logic.node Nope tick', '--op', 'tree.link G 2 1 1', '--op', 'logic.name G 9 4 x',
         '--op', 'edit.undo', '--op', f'file.save {T}/u5.bee']
    for k in range(1, 7):
        if os.path.exists(f'{T}/u{k}.bee'):
            os.remove(f'{T}/u{k}.bee')
    L.run_port(BIN, a)
    c = {k: beefile.chunk(f'{T}/u{k}.bee', b'NTRE') if os.path.exists(f'{T}/u{k}.bee') else None for k in range(1, 7)}
    check(c[1] is not None and c[3] == c[1] and c[4] == c[2] and c[2] != c[1], 'three logic operators undone: the graph as it was; redone: as it became')
    check(c[5] is not None and c[5] == c[6], 'three failed operators make no undo step: the undo after them takes the name back')


def s_fuzz(geo, rng):
    print(f'-- random words for the operators (seed {SEED}) --')
    words = ['', 'G', 'X', 'tick', 'math', '1', '2', '3', '4', '7', '8', '-1', '0', '1e30', 'nan', 'inf', '1:0', '2:1', '1:256', 'Coin', 'Camera', 'abc', '%', '999999999999']
    opsn = ['logic.new', 'logic.node', 'logic.name', 'logic.attach', 'tree.link', 'tree.node_set', 'tree.node_delete', 'tree.node_move', 'tree.new']
    bad = []
    for run_ in range(RUNS * 2):
        a = ['--op', f'file.open {geo}', '--op', 'logic.new G', '--op', 'logic.node G tick', '--op', 'logic.node G move']
        for _ in range(60):
            o = rng.choice(opsn)
            ws = ' '.join(rng.choice(words + TYPES) for _ in range(rng.randrange(0, 6)))
            a += ['--op', f'{o} {ws}']
            if rng.random() < 0.1:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo', 'play.start fly 0 3 6', 'play.stop', 'play.stop keep'])]
            if rng.random() < 0.1:
                a += ['--play', f'step {rng.choice([0.05, 0.3])} 1 0 0']
        a += ['--op', f'file.save {T}/fz.bee']
        r = L.run_port(BIN, a, timeout=600)
        if r is None or r.returncode != 0:
            bad.append((run_, r and r.returncode, r and r.stderr[-300:]))
    for b in bad[:3]:
        print('      ', b)
    check(not bad, f'{RUNS * 2} sessions of 60 random operators with random words, play between: no crash, no hang')


def main():
    print(f'  -- logic graphs (seed {SEED}) --')
    rng = random.Random(SEED)
    geo = make('geo', GEO)
    level = f'{T}/level.bee'
    L.run_script(BIN, f'op("file.open", "{geo}")\n' + ops_code(GRAPHS) + f'\nop("file.save", "{level}")\n')
    try:
        if want('s_ops'):
            s_ops(geo)
        if want('s_play'):
            s_play(level)
        if want('s_same'):
            s_same(level)
        if want('s_storm'):
            s_storm(geo)
        if want('s_nodes'):
            s_nodes(geo)
        if want('s_mods'):
            s_mods(geo)
        if want('s_random'):
            s_random(geo, rng)
        if want('s_damaged'):
            s_damaged(level, rng)
        if want('s_files'):
            s_files(level, geo)
        if want('s_undo'):
            s_undo(geo)
        if want('s_fuzz'):
            s_fuzz(geo, rng)
    finally:
        L.cleanup()
    print(f'\nlogic ... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
