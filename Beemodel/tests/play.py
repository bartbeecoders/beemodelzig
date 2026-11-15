#!/usr/bin/env python3
"""Play mode (play.zig), BeeModel on its own.

A walkthrough level (a floor, walls, stairs up to a platform, a ramp and a
slope too steep to walk, a stack of rigid boxes, a keyed spinner) is made by
BeeModel (--run). Sessions are played two ways by the same build (--play step
/ look / key from the command line, and BeeScript playstep / playlook /
playkey: tests/playlib.py) and every number play mode exposes must be the same
bits both ways, and finite, every tenth of a second: the feet, on the ground,
the velocity, the mode, yaw, pitch, seconds played, the frame, steps taken,
the meshes with a grid, the player's up; and the rigid boxes and the spinner
the scene runs meanwhile.

  * s_walk: the walkthrough: it falls onto the floor, walks into the wall, up
    the stairs onto the platform, up the ramp, not up the steep slope, jumps,
    flies;
  * s_edges: half off the platform's rim and corners, a 54 degree slope (a
    wall), into the walls' corner;
  * s_random: random sessions: starts, looks, keys held (walk, run, jump, fly
    up and down), walk / fly switched;
  * s_planet: a planet (field.add_planet): the pull turns the player's up as it
    walks round it;
  * s_ride: a keyed platform carries the player;
  * s_eye: play.start without a place: from the viewport's eye;
  * s_keys: the keys: F switches, Esc asks (state 2), K keeps, D or Esc
    discards, keys while asking do nothing else;
  * s_restore: leaving play: discarded, the scene saved again is the file saved
    before it byte for byte (the frame, the view too); kept, one undo step
    that takes all of it back; the undo history before play untouched; a
    session left in the middle of a step;
  * s_window: in a window (tests/playwin.py: headless, then the fake
    compositor): F5, W held, the mouse, Esc and the question, K and D;
  * s_fuzz: random operators, words and keys in play mode on this build;
  * s_time, s_memory: a step's time at 200 rigid bodies (a release build, one
    CPU: said, not judged); memory over a long play.

    python3 tests/play.py BIN [runs=6] [seed]

BEE_CPU (default 12) pins BeeModel; PLAY_ONLY=s_walk,s_keys ... runs some;
PLAY_REL=a release build for s_time and s_memory (else skipped).
"""
import os, random, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import playlib as L  # noqa: E402 (its HOME of our own)
import beefile  # noqa: E402

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('PLAY_ONLY', '').split(',') if x]
REL = os.environ.get('PLAY_REL')
T = L.T
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


LEVEL = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 30)
add("cube", "WallN", 0, 1.5, -12)
scale("WallN", 12, 1.5, 0.2)
add("cube", "WallE", 12, 1.5, 0)
scale("WallE", 0.2, 1.5, 12)
for i in 0..6 {
 s = add("cube", "Stair" + str(i), -6, 0.125 + 0.125 * i, -2 - 0.5 * i)
 scale(s, 1.2, 0.125 + 0.125 * i, 0.25)
}
add("cube", "Platform", -6, 0.75, -6)
scale("Platform", 1.2, 0.75, 1.2)
add("cube", "Ramp", 4, 0, -4)
scale("Ramp", 1.2, 0.1, 3)
rotate("Ramp", 0.3, 0, 0)
add("cube", "Steep", 8, 0, -4)
scale("Steep", 1.2, 0.1, 3)
rotate("Steep", 1.15, 0, 0)
for k in 0..4 {
 b = add("cube", "Box" + str(k), 2 + 0.1 * k, 1 + 1.1 * k, 4)
 scale(b, 0.5)
}
select("Box0", "Box1", "Box2", "Box3")
op("rigid.add", "active box")
select("Floor")
op("rigid.add", "passive box")
add("cube", "Mid", -11, 0, -4)
scale("Mid", 1.2, 0.1, 3)
rotate("Mid", 0.95, 0, 0)
add("cube", "Spinner", -3, 1, 5)
key("Spinner:ry", 1, 0, "linear")
key("Spinner:ry", 49, 6.28, "linear")
select()
'''

PLANET = '''
delete("Cube")
op("field.add_planet")
add("cube", "Hut", 0, 10.5, 0)
scale("Hut", 1, 0.5, 1)
select()
'''

RIDE = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 30)
add("cube", "Plat", -4, 0.25, 0)
scale("Plat", 1.5, 0.25, 1.5)
key("Plat:x", 1, -4, "linear")
key("Plat:x", 97, 4, "linear")
key("Plat:y", 1, 0.25, "linear")
key("Plat:y", 49, 1.25, "linear")
key("Plat:y", 97, 0.25, "linear")
select()
'''


def make(name, code):
    path = f'{T}/{name}.bee'
    out, err = L.run_script(BIN, code + f'\nop("file.save", "{path}")\n')
    if not os.path.exists(path):
        print(out[-500:], err[-500:])
    return path


def want(sec):
    return not ONLY or sec in ONLY


def run(actions, what, pre=None):
    oa, pa, d, r = L.session(BIN, BIN, actions, prefix=pre)
    d = d or L.not_finite(pa)
    check(d is None and len(pa) > 0, f'{what}: {len(pa)} moments, every number finite and the same bits by --play and by BeeScript' + (f' ({d})' if d else ''))
    return {t: v for t, v in pa}, d


def every(n, dt, keys=(), items=('p',), tag='D'):
    out = []
    for i in range(n):
        out.append(('step', dt) + tuple(keys))
        out.append(('dump', f'{tag}{i}', list(items)))
    return out


# ---- s_walk -------------------------------------------------------------------------------------

def s_walk(level):
    print('-- the walkthrough --')
    o = [('op', 'file.open', level)]
    a = o + [('op', 'play.start', 'walk 0 4 0')] + every(15, 0.1, items=('p', 'o:Box3', 'o:Spinner'), tag='F')
    a += [('look', 0, 0)] + every(40, 0.1, (1, 0, 0), items=('p', 'o:Box3'), tag='W')
    p, _ = run(a, 'it falls onto the floor, walks north into the wall while the boxes fall and the spinner turns')
    if p:
        f, w = p.get('F14'), p.get('W39')
        check(f and f[2] < 0.01 and f[4] == 1 if f else False, f'stood on the floor ({f and f[1:5]})')
        check(w and abs(w[3] + 11.5) < 0.01 and w[4] == 1 if w else False, f'stopped by the wall: its face at z -11.8, the capsule 0.3 wide ({w and w[1:5]})')
        check(w and w[19 + 1] < 4 and w[12] > 120 if w else False, f'meanwhile the top box fell to {w and w[20]:.2f}, the frame went on to {w and w[12]:.0f}')
    a = o + [('op', 'play.start', 'walk -6 1.8 1')] + every(5, 0.1, tag='A') + [('look', 0, 0)] + every(16, 0.1, (1, 0, 0), tag='S')
    a += [('op', 'play.stop', ''), ('op', 'play.start', 'walk 4 1.8 0')] + every(5, 0.1, tag='B') + [('look', 0, 0)] + every(16, 0.1, (1, 0, 0), tag='R')
    p, _ = run(a, 'up the stairs onto the platform; up the ramp')
    if p:
        s, rr = p.get('S15'), p.get('R15')
        check(s and s[2] > 1.4 and s[4] == 1 if s else False, f'up the stairs (0.25 m each) onto the platform at 1.5 m ({s and s[1:5]})')
        check(rr and rr[2] > 0.5 if rr else False, f'up the ramp ({rr and rr[2]:.2f} m)')
    a = o + [('op', 'play.start', 'walk 8 1.8 0')] + every(5, 0.1, tag='A') + [('look', 0, 0)] + every(30, 0.1, (1, 0, 0), tag='S')
    a += [('step', 0.15, 0, 0, 1), ('dump', 'J', ['p']), ('step', 1), ('dump', 'D', ['p']), ('op', 'play.mode', 'fly'), ('look', 0, -45)]
    a += every(10, 0.1, (1, 0, 0), tag='F') + every(5, 0.1, (0, 0, 1, 1), tag='U') + every(5, 0.1, (0, 0, -1), tag='C')
    p, _ = run(a, 'not up the steep slope; Space jumps and it lands; fly mode goes where it looks, up, down')
    if p:
        s, j, dn, f = p.get('S29'), p.get('J'), p.get('D'), p.get('F9')
        check(s and s[2] < 0.05 and s[3] > -5 if s else False, f'stopped at the steep slope (z {s and s[3]:.2f})')
        check(j and dn and j[4] == 0 and j[2] > 0.3 and dn[2] < 0.05 and dn[4] == 1 if j and dn else False, f'jumped {j and j[2]:.2f} m and landed')
        check(f and f[8] == 2 and f[2] > 5 if f else False, f'flew up where it looked ({f and f[1:4]})')


def s_edges(level):
    print('-- on edges and corners: the platform\'s rim, a slope of 54 degrees --')
    a = [('op', 'file.open', level)]
    k = 0
    for x, z in ((-4.62, -6), (-7.38, -6), (-6, -4.62), (-6, -7.38), (-4.65, -4.65), (-7.35, -7.35), (-4.7, -7.33), (-7.31, -4.68)):
        a += [('op', 'play.start', f'walk {x} 3.5 {z}')] + every(4, 0.25, tag=f'E{k}x') + [('op', 'play.stop', '')]
        k += 1
    a += [('op', 'play.start', 'walk -11 1.8 0'), ('look', 0, 0)] + every(12, 0.25, (1, 0, 0), tag='M') + [('op', 'play.stop', '')]
    a += [('op', 'play.start', 'walk 11 1.8 -11'), ('look', -45, 0)] + every(8, 0.25, (1, 0, 0), tag='C') + [('step', 0.5, 1, 1, 1), ('dump', 'CJ', ['p'])]
    p, _ = run(a, 'standing half off the platform\'s rim and corners, at the 54 degree slope, in the walls\' corner')
    if p:
        m = p.get('M11')
        check(m and m[2] < 0.05 if m else False, f'the 54 degree slope is a wall (feet at {m and m[2]:.2f})')


# ---- s_random -------------------------------------------------------------------------------------

def s_random(level, rng):
    print(f'-- random sessions on the level (seed {SEED}) --')
    bad = 0
    for run_ in range(RUNS):
        x, y, z = rng.uniform(-10, 10), rng.uniform(1, 5), rng.uniform(-10, 10)
        mode = rng.choice(['walk', 'walk', 'fly'])
        a = [('op', 'file.open', level), ('op', 'play.start', f'{mode} {x:.3f} {y:.3f} {z:.3f}')]
        for k in range(45):
            r = rng.random()
            if r < 0.12:
                a.append(('look', round(rng.uniform(-180, 180), 2), round(rng.uniform(-80, 80), 2)))
            elif r < 0.16:
                a.append(('op', 'play.mode', rng.choice(['walk', 'fly'])))
            elif r < 0.2:
                a.append(('key', 33, 1))
                a.append(('key', 33, 0))
            keys = (rng.choice([-1, 0, 1, 1]), rng.choice([-1, 0, 0, 1]), rng.choice([-1, 0, 0, 0, 1]), rng.choice([0, 0, 1]))
            a.append(('step', rng.choice([0.05, 0.1, 0.13, 0.2])) + keys)
            a.append(('dump', f'D{k}', ['p', 'o:Box3']))
        oa, pa, d, _ = L.session(BIN, BIN, a)
        d = d or L.not_finite(pa)
        if d:
            bad += 1
            print('      ', run_, d)
    check(bad == 0, f'{RUNS} random sessions (starts, looks, keys, walk / fly): {RUNS - bad} finite and the same bits both ways all through')


# ---- s_planet, s_ride, s_eye ------------------------------------------------------------------------

def s_planet(planet):
    print('-- walking round a planet --')
    a = [('op', 'file.open', planet), ('op', 'play.start', 'walk 0 13 0')] + every(20, 0.1, tag='F')
    a += [('look', 30, 0)] + every(30, 0.1, (1, 0, 0), tag='W') + every(10, 0.1, (1, 1, 1, 1), tag='R')
    p, _ = run(a, 'it falls onto the planet and walks round it: its up turns with the pull')
    if p:
        w = p.get('W29')
        check(w and abs(w[17]) < 0.99 and w[4] == 1 if w else False, f'its up turned round ({w and w[16:19]}), on the ground')


def s_ride(ride):
    print('-- a moving platform --')
    a = [('op', 'file.open', ride), ('op', 'play.start', 'walk -4 3 0')] + every(40, 0.1, items=('p', 'o:Plat'), tag='R')
    p, _ = run(a, 'the keyed platform carries the player along and up')
    if p:
        r0, r1 = p.get('R5'), p.get('R39')
        check(r0 and r1 and r1[1] - r0[1] > 3 and r1[4] == 1 if r0 and r1 else False, f'carried from x {r0 and r0[1]:.2f} to {r1 and r1[1]:.2f}, standing')


def s_eye(level):
    print('-- play.start from the viewport\'s eye --')
    a = [('op', 'file.open', level), ('op', 'play.start', '')] + every(10, 0.1, tag='E')
    a += [('op', 'play.stop', ''), ('op', 'play.start', 'fly')] + every(5, 0.1, (1, 0, 0), tag='F')
    run(a, 'walking and flying from where the viewport looks from')


# ---- s_keys ---------------------------------------------------------------------------------------

def s_keys(level):
    print('-- the keys --')
    a = [('op', 'file.open', level), ('op', 'play.start', 'walk 0 2 0'), ('step', 0.5), ('look', 90, 0)]
    a += [('key', 17, 1), ('step', 0.3), ('dump', 'W', ['p']), ('key', 42, 1), ('step', 0.3), ('dump', 'Run', ['p']), ('key', 42, 0), ('key', 17, 0)]
    a += [('key', 33, 1), ('key', 33, 0), ('dump', 'Fly', ['p']), ('key', 57, 1), ('step', 0.2), ('key', 57, 0), ('dump', 'Up', ['p'])]
    a += [('key', 46, 1), ('step', 0.2), ('key', 46, 0), ('key', 29, 1), ('step', 0.1), ('key', 29, 0), ('dump', 'Down', ['p'])]
    a += [('key', 33, 1), ('key', 33, 0), ('step', 1), ('dump', 'Walk', ['p']), ('key', 30, 1), ('key', 31, 1), ('step', 0.4), ('key', 30, 0), ('key', 31, 0)]
    a += [('key', 32, 1), ('key', 57, 1), ('step', 0.2), ('key', 57, 0), ('key', 32, 0), ('dump', 'Jump', ['p', 'o:Box3'])]
    a += [('key', 1, 1), ('key', 1, 0), ('dump', 'Ask', ['p']), ('key', 17, 1), ('key', 33, 1), ('key', 17, 0), ('step', 0.5), ('dump', 'Still', ['p'])]
    a += [('key', 37, 0), ('dump', 'Up37', ['p']), ('key', 37, 1), ('dump', 'Kept', ['p', 'o:Box3'])]
    a += [('op', 'play.start', 'walk 0 2 0'), ('step', 0.5), ('key', 1, 1), ('key', 32, 1), ('dump', 'Gone', ['p', 'o:Box3'])]
    a += [('op', 'play.start', 'fly 1 2 3'), ('step', 0.5), ('key', 1, 1), ('key', 1, 1), ('dump', 'EscEsc', ['p', 'o:Box3'])]
    p, _ = run(a, 'W, Shift, F, Space, C, Ctrl, A, S, D; Esc asks, keys then do nothing, K keeps; Esc D, Esc Esc discard')
    if p:
        fl, wk = p.get('Fly'), p.get('Walk')
        check(fl and wk and fl[8] == 2 and wk[8] != 2 if fl and wk else False, f'F flies (mode {fl and fl[8]:.0f}), F again walks (mode {wk and wk[8]:.0f})')
        check(p.get('Ask', [0])[0] == 2 and p.get('Still', [0])[0] == 2 and p.get('Kept', [1])[0] == 0 and p.get('Gone', [1])[0] == 0,
              f'Esc asks (state {p.get("Ask", [0])[0]:.0f}); K keeps, D discards (state 0)')


# ---- s_restore ------------------------------------------------------------------------------------

def chunks_same(a, b, skip=(b'THMB',)):
    ca = [(t, c) for t, c in beefile.chunks(a) if t not in skip]
    cb = [(t, c) for t, c in beefile.chunks(b) if t not in skip]
    return [t for (t, c), (t2, c2) in zip(ca, cb) if c != c2 or t != t2] + ([b'count'] if len(ca) != len(cb) else [])


def objs(path):
    return beefile.objects(path)


def s_restore(level):
    print('-- leaving play: the scene as it was, or kept as one step --')
    o = [('op', 'file.open', level), ('op', 'anim.frame', '7'), ('sel', 'WallE'), ('op', 'object.hide', ''), ('save', f'{T}/before.bee')]
    # (a box hidden while playing: what the simulation does not give back by itself)
    play = [('op', 'play.start', 'walk 0 3 0'), ('look', 20, 10), ('step', 1.5, 1, 0, 0, 1), ('sel', 'Ramp'), ('op', 'object.hide', ''), ('step', 0.2)]
    # the port alone: discarded, saved again: the same bytes
    a = o + play + [('op', 'play.stop', 'discard'), ('save', f'{T}/after.bee'), ('dump', 'After', ['p', 'o:Box3', 'o:WallE'])]
    a2 = o + play + [('op', 'play.stop', 'keep'), ('save', f'{T}/kept.bee'), ('dump', 'Kept', ['p', 'o:Box3']), ('op', 'edit.undo', ''), ('save', f'{T}/undone.bee'),
                     ('dump', 'Undone', ['o:Box3', 'o:WallE']), ('op', 'edit.undo', ''), ('save', f'{T}/undone2.bee'), ('dump', 'Undone2', ['o:WallE']),
                     ('op', 'edit.redo', ''), ('op', 'edit.redo', ''), ('save', f'{T}/redone.bee'), ('dump', 'Redone', ['o:Box3'])]
    for f in ('before', 'after', 'kept', 'undone', 'undone2', 'redone'):
        if os.path.exists(f'{T}/{f}.bee'):
            os.remove(f'{T}/{f}.bee')
    dump = f'{T}/rdump.txt'
    if os.path.exists(dump):
        os.remove(dump)
    L.run_port(BIN, L.port_args(a, dump))
    d1 = chunks_same(f'{T}/before.bee', f'{T}/after.bee') if os.path.exists(f'{T}/after.bee') else ['missing']
    check(d1 == [], f'discarded: the scene saved after play is the one saved before it, byte for byte (the boxes, the frame, the view{"; apart: " + str(d1) if d1 else ""})')
    pb = open(f'{T}/before.bee', 'rb').read()
    L.run_port(BIN, L.port_args(a2, dump))
    check('Undo: Play' in L.plog(), 'kept: one undo step called Play')
    ok = os.path.exists(f'{T}/kept.bee') and os.path.exists(f'{T}/undone.bee')
    kept_differs = ok and beefile.chunk(f'{T}/kept.bee', b'OBJS') != beefile.chunk(f'{T}/before.bee', b'OBJS')
    d2 = chunks_same(f'{T}/before.bee', f'{T}/undone.bee', skip=(b'THMB', b'VIEW', b'WSPC', b'ANIM')) if ok else ['missing']
    check(kept_differs and d2 == [], f'kept: the fallen boxes stay; one Ctrl+Z gives the scene before play back (all but the view, which stays at the player\'s eyes, and the frame: not in undo){"; apart: " + str(d2) if d2 else ""}')
    d3 = beefile.objects(f'{T}/undone2.bee') if os.path.exists(f'{T}/undone2.bee') else None
    check(d3 is not None and any(x['name'] == 'WallE' and not (x['flags'] & 2) for x in d3) if d3 else False,
          'a second Ctrl+Z undoes the edit made before play (the history before play untouched)')
    # the same scene after discard, after keep, by --play and by BeeScript
    a3 = o + play + [('op', 'play.stop', 'discard'), ('dump', 'After', ['p', 'o:Box3', 'o:Box0', 'o:WallE', 'o:Spinner', 'o:Ramp'])]
    a3 += play + [('op', 'play.stop', 'keep'), ('dump', 'Kept', ['p', 'o:Box3', 'o:Box0', 'o:Spinner'])]
    run(a3, 'discarded, then kept: the scene, the frame and the view (its undo: s_window)')
    # left in the middle: Esc asks between steps, a key held when it stops
    a4 = [('op', 'file.open', level), ('op', 'play.start', 'walk 0 3 0'), ('key', 17, 1), ('step', 0.7), ('key', 1, 1), ('step', 0.5), ('dump', 'Mid', ['p']),
          ('key', 37, 1), ('step', 0.3), ('dump', 'After', ['p', 'o:Box3']), ('op', 'play.start', 'walk 0 3 0'), ('step', 0.3), ('dump', 'Again', ['p'])]
    run(a4, 'stopped with W held: nothing steps while it asks, the next play starts still')


# ---- s_fuzz ---------------------------------------------------------------------------------------

def s_fuzz(level, rng):
    print(f'-- random operators, words and keys while playing (seed {SEED}) --')
    words = ['', 'walk', 'fly', 'keep', 'discard', 'f', 'x', '1e30', '-1e30', 'nan', '0 0 0', '1 2', 'fly 1 2 3 4 5', 'walk a b c', '99999999 0 0', '1e-40 1e38 -3']
    bad = []
    for run_ in range(RUNS * 2):
        a = ['--op', f'file.open {level}']
        for _ in range(40):
            r = rng.random()
            if r < 0.15:
                a += ['--op', 'play.start ' + rng.choice(words)]
            elif r < 0.2:
                a += ['--op', 'play.stop ' + rng.choice(words)]
            elif r < 0.25:
                a += ['--op', 'play.mode ' + rng.choice(words)]
            elif r < 0.45:
                a += ['--play', f'step {rng.choice([0, 0.01, 0.1, 0.5, 2, -1, 1e-30])} {rng.choice([-1, 0, 1])} {rng.choice([-1, 0, 1])} {rng.choice([-1, 0, 1])} {rng.choice([0, 1])}']
            elif r < 0.55:
                a += ['--play', f'look {rng.choice([0, 90, -720, 1e30, -1e30])} {rng.choice([0, 89, -89, 1e30, -1e30])}']
            elif r < 0.75:
                a += ['--play', f'key {rng.choice([1, 17, 30, 31, 32, 33, 37, 42, 46, 57, 29, 18, 300, 0])} {rng.choice([0, 1])}']
            elif r < 0.85:
                a += ['--key', rng.choice(['f5', 'esc', 'w', 'k', 'd', 'f', 'space', 'ctrl+z'])]
            elif r < 0.9:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo', 'anim.frame 30', 'object.delete', 'select.all'])]
            else:
                a += ['--move', f'{rng.randrange(1280)},{rng.randrange(800)}', '--click', f'{rng.randrange(1280)},{rng.randrange(800)}']
        r = L.run_port(BIN, a, timeout=600)
        if r is None or r.returncode != 0:
            bad.append((run_, r and r.returncode, r and r.stderr[-300:]))
    for b in bad[:3]:
        print('      ', b)
    check(not bad, f'{RUNS * 2} random sessions of 40 actions on this build: no crash, no hang')


# ---- s_time, s_memory -------------------------------------------------------------------------------

BODIES = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 40)
select("Floor")
op("rigid.add", "passive box")
for i in 0..200 {
 b = add("cube", "B" + str(i), (i % 10) * 1.3 - 6, 1 + (i / 100) * 3, ((i / 10) % 10) * 1.3 - 6)
 scale(b, 0.5)
 select(b)
 op("rigid.add", "active box")
}
select()
'''


def s_time(rng):
    print('-- the time play takes (a release build, one CPU) --')
    if not REL:
        print('       (PLAY_REL unset: the release build to time; skipped)')
        return
    lvl = make('bodies', BODIES)
    secs = 3
    best_p = base_p = 1e9
    rc = []
    for _ in range(3):
        t0 = time.time()
        r = L.run_port(REL, ['--op', f'file.open {lvl}', '--op', 'play.start walk 0 3 12', '--play', 'look 0 -10', '--play', 'step 0.5', '--play', f'step {secs} 1 0 0'])
        best_p = min(best_p, time.time() - t0)
        rc.append(r.returncode if r is not None else 'hung')
        # the same without play: what opening and the rest take
        t0 = time.time()
        L.run_port(REL, ['--op', f'file.open {lvl}'])
        base_p = min(base_p, time.time() - t0)
    steps = int((secs + 0.5) * 120)
    pp = (best_p - base_p) / steps * 1000
    print(f'       200 bodies, {steps} steps of 1/120 s with the player walking: {pp:.3f} ms a step')
    check(rc == [0, 0, 0], f'a play at 200 rigid bodies on the release build ends cleanly ({rc})')


def s_memory(level):
    print('-- memory over a long play (release build) --')
    if not REL:
        print('       (PLAY_REL unset; skipped)')
        return

    def rss(secs):
        a = ['--op', f'file.open {level}', '--op', 'play.start walk 0 3 0', '--play', 'look 0 0']
        for _ in range(secs // 30):
            a += ['--play', 'step 15 1 0 0', '--play', 'look 180 0', '--play', 'step 15 1 1 0 1']
        w = 'import resource, subprocess, sys; subprocess.run(sys.argv[1:], capture_output=True); print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)'
        r = subprocess.run([sys.executable, '-c', w, 'taskset', '-c', L.CPU, REL, '--shot', f'{T}/u.ppm', *a], capture_output=True, text=True, env=L.ENV, timeout=1800)
        try:
            return int(r.stdout.split()[-1])
        except (ValueError, IndexError):
            return None
    a, b = rss(30), rss(600)
    print(f'       peak memory: {a} KiB after 30 s of play, {b} KiB after 10 minutes')
    check(a and b and b - a < 8 * 1024, f'ten minutes of play (72 000 steps, the boxes, the grids) take no more memory than 30 s ({a} -> {b} KiB)')


# ---- s_window -------------------------------------------------------------------------------------

def s_window(level):
    print('-- in a window: F5, keys, the mouse, Esc, the question (headless, then the fake compositor) --')
    import playwin
    playwin.run(BIN, level, T, check)


def main():
    print(f'  -- play mode (seed {SEED}) --')
    rng = random.Random(SEED)
    level = make('level', LEVEL)
    try:
        if want('s_walk'):
            s_walk(level)
        if want('s_edges'):
            s_edges(level)
        if want('s_random'):
            s_random(level, rng)
        if want('s_planet'):
            s_planet(make('planet', PLANET))
        if want('s_ride'):
            s_ride(make('ride', RIDE))
        if want('s_eye'):
            s_eye(level)
        if want('s_keys'):
            s_keys(level)
        if want('s_restore'):
            s_restore(level)
        if want('s_window'):
            s_window(level)
        if want('s_fuzz'):
            s_fuzz(level, rng)
        if want('s_time'):
            s_time(rng)
        if want('s_memory'):
            s_memory(level)
    finally:
        L.cleanup()
    print(f'\nplay ... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
