#!/usr/bin/env python3
"""Rigging: bone matrices, skinned vertices (linear and dual quaternion), heat
weights, IK solves, every constraint at many frames, each worked out two ways
by BeeModel: from the command line (--op, --dump-verts, files) and from a
BeeScript (--run: evpos, bonepos, prop, files) or, for edit and pose mode, in a
window (keys) read back through its MCP script_eval; the two must agree. ARMT,
MWGT and ANIM's constraints written by one route and read by the other; save ->
open -> save the same chunks; damaged chunks; undo; an idle window. Every
comparison also asserts that what it compares moved, and tests that could pass
on nothing say so.

    python3 tests/rig.py BIN [damage-runs=60] [seed]
"""
import math, os, random, re, socket, struct, subprocess, sys, tempfile
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
FAILS = []
T = tempfile.mkdtemp(prefix='beerig-', dir=os.environ.get('BEERIG_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
# single precision: a matrix through the same operations, printed with 6 decimals by the script
TOL = 1e-5


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def script(code):
    """A BeeScript run by BeeModel (--run, a script in a file: any length): its stdout."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    r = subprocess.run([BIN, '--run', p], capture_output=True, text=True, timeout=600, env=ENV)
    if 'error:' in r.stdout + r.stderr or r.returncode not in (0, 1):
        print((r.stdout + r.stderr)[-600:])
        check(r.returncode in (0, 1), f'the script ended cleanly ({r.returncode})')
    return r.stdout


def port(*a, ok=True):
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a], capture_output=True, text=True, timeout=600, env=ENV)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {a[:6]}')
    return r


def ops(*lines):
    out = []
    for ln in lines:
        out += ['--op', ln]
    return out


def display(path, name='Rig'):
    """The armature's display mesh in a file: the bones' matrices, six points each."""
    objs = beefile.objects(path)
    ms = beefile.meshes(path)
    o = next(x for x in objs if x['name'] == name)
    return [c for v in ms[o['mesh']][0] for c in v]


def clean(c):
    """ARMT's bones in use, without what a name's end leaves behind (whatever follows the name's 0 in its 24 bytes)."""
    b = bytearray(c[4:])
    n = struct.unpack_from('<I', b, 0)[0]
    for i in range(n):
        o = 60 + i * 128
        e = b.index(0, o)
        b[e:o + 24] = bytes(o + 24 - e)
    return bytes(b[:60 + n * 128])


def recs(c):
    """MWGT's records, mesh indices aside: the files order their meshes differently."""
    o, out = 0, []
    while o < len(c):
        nv = struct.unpack_from('<I', c, o + 4)[0]
        out.append(c[o + 4:o + 8 + nv * 20])
        o += 8 + nv * 20
    return out


def rel(a, b):
    return abs(a - b) / max(1.0, abs(a))


def compare(name, a, b, tol=TOL, angles=False):
    if len(a) != len(b) or not a:
        check(False, f'{name}: {len(a)} and {len(b)} values')
        return
    worst = 0
    for k, (x, y) in enumerate(zip(a, b)):
        e = rel(x, y)
        if angles and 3 <= k % 9 < 6:  # (a half turn's sign: -pi and pi are one angle)
            e = min(e, abs(abs(x - y) - 2 * math.pi))
        worst = max(worst, e)
    check(worst <= tol, f'{name}: {len(a)} values, worst error {worst:.2e}')


# the scene -------------------------------------------------------------------------------

BUILD = '''
a = armature("Rig")
op("arm.bone", "Upper Bone 0 1 0 0.3 2 0.1")
op("arm.bone", "Fore Upper 0.3 2 0.1 0.9 2.6 0.1")
op("arm.bone", "Hand Fore 0.9 2.6 0.1 1.5 2.7 0.4")
op("arm.bone", "Side Bone 0 1 0 -1 1.4 0")
op("arm.bone", "Fwd Side -1 1.4 0 -1 1.4 1.2")
move("Rig", 0.2, 0.1, -0.3)
rotate("Rig", 0.1, 0.2, -0.15)
scale("Rig", 1.1, 1.1, 1.1)
add("sphere", "Body", 0.1, 1.6, 0)
scale("Body", 1.2)
add("cylinder", "Limb", 0.5, 2, 0.2)
rotate("Limb", 0.4, 0, 0.8)
scale("Limb", 0.5, 1.4, 0.5)
add("cube", "Goal", 1, 2.2, 0.7)
add("cube", "Pole", 0.3, 3, -2)
op("arm.parent", "Body Rig")
op("arm.parent", "Limb Rig dual")
select("Rig")
'''


def scene():
    p = f'{T}/base.bee'
    if not os.path.exists(p):
        script(BUILD + f'op("file.save", "{p}")\n')
    check(os.path.exists(p), 'the script saved the scene')
    return p


def opened(p, *names):
    """Command-line steps: open the file, then select those objects."""
    return ['--op', f'file.open {p}'] + (['--select', names[0]] if names else [])


POSE = [('Upper', 'rot', 20, -10, 35), ('Fore', 'rot', 0, 30, -40), ('Hand', 'scale', 1.2, 0.8, 1.1), ('Hand', 'loc', 0.1, 0.2, -0.1),
        ('Side', 'rot', 15, 80, 10), ('Fwd', 'rot', -35, 0, 20), ('Bone', 'loc', 0.1, -0.2, 0.05), ('Bone', 'rot', 5, 10, 15)]


def s_pose():
    print('-- bones: rest frames, poses, skinned vertices, linear and dual quaternion --')
    base = scene()
    vb = len(beefile.meshes(base)[next(o for o in beefile.objects(base) if o['name'] == 'Body')['mesh']][0])
    check(vb == 482, f'the body has its {vb} vertices')
    pr = ''.join(f'op("arm.pose", "{b} {w} {x} {y} {z}")\n' for b, w, x, y, z in POSE)
    probe = ''.join(f'i = 0; while i < {n} {{ print("V", evpos("{m}", i, "x")*1000000, evpos("{m}", i, "y")*1000000, evpos("{m}", i, "z")*1000000); i = i + 1 }}\n' for m, n in (('Body', 482), ('Limb', 64)))
    o0 = f'{T}/o0.bee'
    out = script(f'op("file.open", "{base}")\nselect("Rig")\n{probe}{pr}op("file.save", "{o0}")\n{probe}')
    vals = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('V ') for x in ln.split()[1:]]
    check(len(vals) == 2 * (482 + 64) * 3, f'the script gave {len(vals)} numbers')
    rest, posed = vals[:len(vals) // 2], vals[len(vals) // 2:]
    moved = max(abs(a - b) for a, b in zip(rest, posed))
    check(moved > 0.3, f'the pose moved the skin (up to {moved:.3f})')
    px = [f'arm.pose {b} {w} {x} {y} {z}' for b, w, x, y, z in POSE]
    p0 = f'{T}/p0.bee'
    a = opened(base, 'Rig')
    port(*a, '--dump-verts', f'{T}/b0.txt;Body', '--dump-verts', f'{T}/l0.txt;Limb', *ops(*px), '--op', f'file.save {p0}', '--dump-verts', f'{T}/b1.txt;Body', '--dump-verts', f'{T}/l1.txt;Limb')

    def rd(*names):
        return [float.fromhex(x) for n in names for ln in open(f'{T}/{n}.txt') for x in ln.split()]
    compare('rest: linear blend, dual quaternion: the script and --dump-verts agree', rest, rd('b0', 'l0'))
    compare('posed: linear blend, dual quaternion: the script and --dump-verts agree', posed, rd('b1', 'l1'))
    compare('bone matrices (the display mesh): the script\'s file and the command line\'s', display(o0), display(p0), 1e-6)
    a0 = beefile.chunk(o0, b'ARMT')
    b0 = beefile.chunk(p0, b'ARMT')
    check(a0[4:] == b0[4:], 'ARMT: the same bones from the two routes, poses included, byte for byte')


def s_keyed():
    print('-- keyed poses: curves through the bones, at many frames (key() in a script, anim.key on the command line) --')
    base = scene()
    ks = [('bone:Rig:Upper:rz', 1, 0, ''), ('bone:Rig:Upper:rz', 20, 0.9, ''), ('bone:Rig:Upper:rz', 41, -0.5, 'linear'),
          ('bone:Rig:Fore:rx', 1, 0, 'bezier'), ('bone:Rig:Fore:rx', 30, 1.2, 'bezier'), ('bone:Rig:Fore:sy', 5, 1, ''), ('bone:Rig:Fore:sy', 35, 1.6, ''),
          ('bone:Rig:Hand:x', 1, 0, 'constant'), ('bone:Rig:Hand:x', 21, 0.4, 'constant'), ('bone:Rig:Bone:y', 10, 0, ''), ('bone:Rig:Bone:y', 40, 0.5, ''),
          ('Rig:ry', 1, 0, ''), ('Rig:ry', 45, 0.7, '')]
    frames = [1, 6, 11.5, 17, 20, 26, 33, 41, 47]
    ok = ''.join(f'key("{p}", {f}, {v}{", " + chr(34) + i + chr(34) if i else ""})\n' for p, f, v, i in ks)
    probe = 'i = 0; while i < 482 { print("V", evpos("Body", i, "x")*1000000, evpos("Body", i, "y")*1000000, evpos("Body", i, "z")*1000000, weight("Body", i, 1)); i = i + 40 }\n'
    code = f'op("file.open", "{base}")\nselect("Rig")\n{ok}'
    for k, f in enumerate(frames):
        code += f'frame({f})\nop("file.save", "{T}/ok{k}.bee")\n{probe}'
    out = script(code)
    want = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('V ') for x in ln.split()[1:4]]
    a = opened(base, 'Rig') + ops(*[f'anim.key {p} {f} {v} {i}'.strip() for p, f, v, i in ks])
    for k, f in enumerate(frames):
        a += ops(f'anim.frame {f}', f'file.save {T}/pk{k}.bee') + ['--dump-verts', f'{T}/k{k}.txt;Body']
    port(*a)
    got = []
    for k in range(len(frames)):
        v = [float.fromhex(x) for ln in open(f'{T}/k{k}.txt') for x in ln.split()]
        for i in range(0, 482, 40):
            got += v[i * 3:i * 3 + 3]
    compare('skinned, frame by frame', want, got)
    a0 = [c for k in range(len(frames)) for c in display(f'{T}/ok{k}.bee')]
    b0 = [c for k in range(len(frames)) for c in display(f'{T}/pk{k}.bee')]
    compare('bone matrices, frame by frame', a0, b0, 2e-6)
    check(max(abs(x - y) for x, y in zip(display(f'{T}/ok0.bee'), display(f'{T}/ok3.bee'))) > 0.2, 'the bones moved between the frames')
    ca = beefile.chunk(f'{T}/ok8.bee', b'ANIM')
    cb = beefile.chunk(f'{T}/pk8.bee', b'ANIM')
    n = struct.unpack_from('<I', ca, 8)[0]  # (the curves' count in the head)
    check(n == 6 and ca[64 + 4:64 + 4 + 32 * n] == cb[64 + 4:64 + 4 + 32 * n], f'ANIM: {n} curves, the same bytes from the two routes')
    ka = ca[-32 * 13:]
    check(ka == cb[-32 * 13:], 'ANIM: the bone keys, the same bytes from the two routes')


IKS = [('fabrik, two bones', 'Rig:Hand ik Goal chain 2', 0), ('fabrik, to the root', 'Rig:Hand ik Goal', 0), ('fabrik, chain 3', 'Rig:Hand ik Goal chain 3', 0),
       ('ccd', 'Rig:Hand ik Goal chain 3 solver ccd', 0), ('ccd, few iterations', 'Rig:Hand ik Goal chain 2 solver ccd iterations 3', 0),
       ('fabrik, few iterations', 'Rig:Hand ik Goal chain 3 iterations 2', 0), ('a pole', 'Rig:Hand ik Goal chain 3 pole Pole', 0), ('ccd, a pole', 'Rig:Hand ik Goal chain 2 pole Pole solver ccd', 0),
       ('influence', 'Rig:Hand ik Goal chain 3 influence 0.4', 0), ('out of reach', 'Rig:Hand ik Goal chain 2', 6), ('a branch', 'Rig:Fwd ik Goal chain 2', 0),
       ('one bone', 'Rig:Hand ik Goal chain 1', 0)]


def s_ik():
    print('-- IK: solves, target moving: the script\'s readouts and the command line\'s files agree --')
    base = scene()
    ks = [('Goal:x', 1, 1, ''), ('Goal:x', 30, -0.4, ''), ('Goal:y', 1, 2.2, ''), ('Goal:y', 30, 3.1, ''), ('Goal:z', 1, 0.7, ''), ('Goal:z', 30, -0.8, ''), ('Pole:x', 1, 0.3, ''), ('Pole:x', 30, -2, '')]
    frames = [1, 5, 12, 19, 26, 30]
    for name, con, far in IKS:
        ks2 = ks + ([('Goal:x', 1, 1 + far, ''), ('Goal:x', 30, 3 + far, '')] if far else [])
        ok = ''.join(f'key("{p}", {f}, {v})\n' for p, f, v, _ in ks2)
        code = f'op("file.open", "{base}")\n{ok}op("constraint.add", "{con}")\n'
        for k, f in enumerate(frames):
            code += f'frame({f})\nprint("B", bonepos("Rig", "Hand", "x")*1000000, bonepos("Rig", "Hand", "y")*1000000, bonepos("Rig", "Hand", "z")*1000000, bonepos("Rig", "Fwd", "x")*1000000, evpos("Body", 300, "y")*1000000, evpos("Limb", 40, "z")*1000000)\nop("file.save", "{T}/oi{k}.bee")\n'
        out = script(code)
        want = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('B ') for x in ln.split()[1:]]
        a = opened(base, 'Rig') + ops(*[f'anim.key {p} {f} {v}' for p, f, v, _ in ks2], f'constraint.add {con}')
        for k, f in enumerate(frames):
            a += ops(f'anim.frame {f}', f'file.save {T}/pi{k}.bee') + ['--dump-verts', f'{T}/vb{k}.txt;Body', '--dump-verts', f'{T}/vl{k}.txt;Limb']
        port(*a)
        a0 = [c for k in range(len(frames)) for c in display(f'{T}/oi{k}.bee')]
        b0 = [c for k in range(len(frames)) for c in display(f'{T}/pi{k}.bee')]
        compare(f'{name}: matrices', a0, b0, 3e-6)
        check(max(abs(x - y) for x, y in zip(display(f'{T}/oi0.bee'), display(f'{T}/oi5.bee'))) > 0.05, f'{name}: the target moved the bones')
        check(len(want) == 6 * len(frames), f'{name}: the script gave its solves')
        got = []
        for k in range(len(frames)):
            vb = [float.fromhex(x) for ln in open(f'{T}/vb{k}.txt') for x in ln.split()]
            vl = [float.fromhex(x) for ln in open(f'{T}/vl{k}.txt') for x in ln.split()]
            got += [vb[300 * 3 + 1], vl[40 * 3 + 2]]
        compare(f'{name}: the skin follows', [x for k, x in enumerate(want) if k % 6 >= 4], got, 3e-6)


CHAN = [f'Fol:{a}' for a in ('x', 'y', 'z', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz')]
CONS = [('copy location', ['Fol copy_location Tgt'], ()), ('copy location, axes, offset', ['Fol copy_location Tgt axes xz offset'], ()), ('copy location, half', ['Fol copy_location Tgt influence 0.5'], ()),
        ('copy rotation', ['Fol copy_rotation Tgt'], ()), ('copy rotation, y, offset', ['Fol copy_rotation Tgt axes y offset'], ()),
        ('copy scale', ['Fol copy_scale Tgt'], ()), ('copy scale, offset', ['Fol copy_scale Tgt offset influence 0.7'], ()),
        ('limit location', ['Fol limit_location min -1 -1 -1 max 1 1.5 0.5'], ()), ('limit location, the floor', ['Fol limit_location min 0.1 0.5 0 max 9 9 9'], ()), ('limit rotation, the floor', ['Fol limit_rotation min 10 -5 20 max 170 170 170'], ()), ('limit scale, the floor', ['Fol limit_scale min 1.4 1.5 1.3 max 9 9 9'], ()), ('limit rotation', ['Fol limit_rotation axes xz min -20 -30 -40 max 20 30 10'], ()), ('limit scale', ['Fol limit_scale axes y min 0.5 0.8 0.5 max 2 1.2 2 influence 0.5'], ()),
        ('child of', ['Fol child_of Tgt'], ()), ('child of, half', ['Fol child_of Tgt influence 0.6'], ()),
        ('copy and limit', ['Fol copy_location Tgt', 'Fol limit_location axes y min 0 0 0 max 0 2 0'], ()), ('child, then track', ['Fol child_of Tgt', 'Fol track_to Oth track y up z'], ()),
        ('muted', ['Fol copy_location Tgt'], ('mute',))]
for tr in ('x', 'y', 'z', '-x', '-y', '-z'):
    for up in ('x', 'y', 'z'):
        CONS.append((f'track {tr} up {up}', [f'Fol track_to Tgt track {tr} up {up}'], ()))


def s_constraints():
    print('-- constraints: every kind at many frames --')
    keys = ''.join(f'key("{p}", {f}, {v})\n' for p, f, v in (('Tgt:x', 1, 2), ('Tgt:x', 50, -3), ('Tgt:y', 1, 0.5), ('Tgt:y', 50, 4), ('Tgt:z', 1, -1), ('Tgt:z', 25, 2), ('Tgt:z', 50, -2),
                                                                ('Tgt:rx', 1, 0), ('Tgt:rx', 50, 1.2), ('Tgt:ry', 1, -0.5), ('Tgt:ry', 50, 0.9), ('Tgt:rz', 1, 0.2), ('Tgt:rz', 50, -1), ('Tgt:sx', 1, 1), ('Tgt:sx', 50, 2.5), ('Tgt:sy', 1, 1.5), ('Tgt:sy', 50, 0.6), ('Tgt:sz', 1, 0.4), ('Tgt:sz', 50, 1.3),
                                                                ('Fol:x', 1, 0.5), ('Fol:x', 50, -0.7), ('Fol:ry', 1, 0.3), ('Fol:ry', 50, -0.6), ('Fol:rz', 1, 0), ('Fol:rz', 50, 0.8), ('Fol:sy', 1, 1), ('Fol:sy', 50, 1.8), ('Oth:y', 1, 3), ('Oth:y', 50, -2)))
    b = f'{T}/cons.bee'
    script('add("cube", "Fol", 0.5, 0.2, -0.4)\nscale("Fol", 1.2, 0.8, 1.1)\nadd("cube", "Tgt", 2, 0.5, -1)\nadd("sphere", "Oth", 1, 3, 2)\n' + keys + f'frame(7)\nop("file.save", "{b}")\n')
    check(os.path.exists(b), 'the scene saved')
    frames = [1 + 2.5 * k for k in range(21)]
    pr = ', '.join(f'prop("{c}")*1000000' for c in CHAN)
    for name, cs, extra in CONS:
        code = f'op("file.open", "{b}")\n' + ''.join(f'op("constraint.add", "{c}")\n' for c in cs)
        lines = [f'constraint.add {c}' for c in cs]
        if 'mute' in extra:
            code += 'op("constraint.set", "1 mute 1")\n'
            lines.append('constraint.set 1 mute 1')
        for f in frames:
            code += f'frame({f})\nprint("V", {f}, {pr})\n'
        out = script(code)
        want = {float(ln.split()[1]): [float(x) / 1e6 for ln2 in [ln] for x in ln2.split()[2:]] for ln in out.splitlines() if ln.startswith('V ')}
        o = f'{T}/d.txt'
        if os.path.exists(o):
            os.unlink(o)
        a = ['--op', f'file.open {b}'] + ops(*lines)
        rows = {}
        for f in frames:
            a += ['--dump-chan', f'{o}{len(rows)};{f};{f};1;' + ';'.join(CHAN)]  # (it goes to the frame: once)
            rows[f] = f'{o}{len(rows)}'
        port(*a)
        wv, gv = [], []
        for f in frames:
            w = open(rows[f]).read().split()
            gv += [float.fromhex(x) for x in w[1:]]
            wv += want.get(f, [])
        compare(name, wv, gv, 3e-6, angles=True)
        check(len(set(round(x, 3) for x in wv[::9])) > 1 or 'limit' in name or 'rotation' in name or 'scale' in name or 'track' in name, f'{name}: it moved')
    # the same frames with no constraint: a constraint must change something
    code = f'op("file.open", "{b}")\n'
    for f in frames:
        code += f'frame({f})\nprint("V", {f}, {pr})\n'
    plain = [float(x) / 1e6 for ln in script(code).splitlines() if ln.startswith('V ') for x in ln.split()[2:]]
    code = f'op("file.open", "{b}")\nop("constraint.add", "Fol limit_rotation axes xz min -20 -30 -40 max 20 30 10")\n'
    for f in frames:
        code += f'frame({f})\nprint("V", {f}, {pr})\n'
    lim = [float(x) / 1e6 for ln in script(code).splitlines() if ln.startswith('V ') for x in ln.split()[2:]]
    check(max(abs(x - y) for x, y in zip(plain, lim)) > 0.01, 'a limit changes what the keys say')


def s_heat():
    print('-- automatic weights: MWGT byte for byte, the script and the command line --')
    sets = [('a sphere', 'add("sphere", "M", 0.2, 1.5, 0)\nscale("M", 1.1)\n'), ('a cylinder, turned', 'add("cylinder", "M", 0, 1.5, 0.3)\nrotate("M", 0.3, 0.5, 0.2)\nscale("M", 0.5, 1.5, 0.7)\n'),
            ('a plane (open)', 'add("plane", "M", 0, 1, 0)\n'), ('a cube', 'add("cube", "M", 0, 2, 0)\n'), ('a torus', 'add("torus", "M", 0, 2, 0)\n')]
    bones = 'armature("Rig")\nop("arm.bone", "B Bone 0 1 0 0 2 0")\nop("arm.bone", "C B 0 2 0 0.8 2.6 0.2")\nop("arm.bone", "D B 0 2 0 -0.9 2.2 0.1")\nop("arm.bone", "E C 0.8 2.6 0.2 0.8 3.4 0")\nop("arm.bone", "F Bone 0 0.2 0 0.5 -0.7 0.3")\nmove("Rig", 0.1, -0.2, 0.05)\n'
    for name, add in sets:
        p = f'{T}/h.bee'
        script(bones + add + f'op("file.save", "{p}")\n')
        o = f'{T}/ho.bee'
        script(f'op("file.open", "{p}")\nop("arm.parent", "M Rig")\nop("file.save", "{o}")\n')
        q = f'{T}/hp.bee'
        port('--op', f'file.open {p}', *ops('arm.parent M Rig', f'file.save {q}'))
        a = beefile.chunk(o, b'MWGT')
        b = beefile.chunk(q, b'MWGT')
        nv = struct.unpack_from('<I', a, 4)[0]
        used = {a[8 + k * 20 + c] for k in range(nv) for c in range(4)} - {255}
        check(a[4:] == b[4:] and len(a) == 8 + nv * 20, f'{name}: {nv} vertices, {len(used)} bones, the same bytes')
        check(len(used) >= 2, f'{name}: the weights are spread over the bones')
        am = beefile.chunk(o, b'MODS')
        check(am == beefile.chunk(q, b'MODS'), f'{name}: the Armature modifier the same, its handle too')


def s_files():
    print('-- files: a script reads what the command line wrote, and the other way round --')
    base = scene()
    a = opened(base, 'Rig') + ops(*[f'arm.pose {b} {w} {x} {y} {z}' for b, w, x, y, z in POSE], 'constraint.add Rig:Hand ik Goal chain 3 pole Pole', 'constraint.add Pole copy_location Goal axes y offset',
                                  'anim.key bone:Rig:Upper:rz 1 0.2', 'anim.key bone:Rig:Upper:rz 30 -0.4', 'anim.key Goal:x 1 1', 'anim.key Goal:x 30 -1', 'anim.frame 11', f'file.save {T}/pf.bee')
    port(*a)
    pr = 'print("B", bonepos("Rig", "Hand", "x")*1000000, bonepos("Rig", "Hand", "y")*1000000, evpos("Body", 300, "y")*1000000, evpos("Limb", 40, "z")*1000000)\n'
    # the command line's file opened by a script, and the script's file by the command line
    out = script(f'op("file.open", "{T}/pf.bee")\n{pr}frame(23)\n{pr}op("file.save", "{T}/of.bee")\n')
    w = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('B ') for x in ln.split()[1:]]
    check(len(w) == 8, 'the script evaluated the file')
    port('--op', f'file.open {T}/pf.bee', '--dump-rig', f'{T}/r0.txt;Rig', '--dump-verts', f'{T}/b.txt;Body', '--dump-verts', f'{T}/l.txt;Limb', *ops('anim.frame 23'), '--dump-verts', f'{T}/b2.txt;Body', '--dump-verts', f'{T}/l2.txt;Limb', *ops(f'file.save {T}/pg.bee'))

    def vrt(n, i, c):
        return float.fromhex(open(f'{T}/{n}.txt').read().splitlines()[i].split()[c])
    compare('the skin the script sees in the file', [w[2], w[3], w[6], w[7]], [vrt('b', 300, 1), vrt('l', 40, 2), vrt('b2', 300, 1), vrt('l2', 40, 2)], 2e-6)
    check(abs(w[2] - w[6]) > 1e-3, 'the frames differ')
    compare('the bones the script saves from it', display(f'{T}/of.bee'), display(f'{T}/pg.bee'), 3e-6)
    # save -> open -> save
    a0 = dict(beefile.chunks(f'{T}/pf.bee'))
    port('--op', f'file.open {T}/pf.bee', *ops(f'file.save {T}/ph.bee'))
    a1 = dict(beefile.chunks(f'{T}/ph.bee'))
    for t in (b'ARMT', b'MWGT', b'MODS', b'ANIM'):
        check(a0[t] == a1[t], f'{t.decode()} comes back the same')
    # the script's file, through the command line, unchanged
    o = f'{T}/ow.bee'
    script(f'op("file.open", "{base}")\nselect("Rig")\nop("arm.pose", "Upper rot 10 20 30")\nop("constraint.add", "Rig:Hand ik Goal chain 2")\nop("constraint.add", "Pole track_to Goal")\nframe(4)\nop("file.save", "{o}")\n')
    port('--op', f'file.open {o}', *ops(f'file.save {T}/ow2.bee'))
    c0 = dict(beefile.chunks(o))
    c1 = dict(beefile.chunks(f'{T}/ow2.bee'))
    check(c0[b'ARMT'][4:] == c1[b'ARMT'][4:], 'the script\'s ARMT through the command line: the same bytes')
    check(recs(c0[b'MWGT']) == recs(c1[b'MWGT']) and len(recs(c0[b'MWGT'])) == 2, 'the script\'s MWGT through the command line')
    con = 35392 + 4
    n = struct.unpack_from('<I', c0[b'ANIM'], 48)[0]
    check(n == 2 and c0[b'ANIM'][con:con + n * 192] == c1[b'ANIM'][con:con + n * 192], f'ANIM: {n} constraints through the command line, the same bytes')
    # an armature among the first objects of a file: the handle must still find it
    p = f'{T}/first.bee'
    port('--op', 'help.template character', '--op', f'file.save {p}')
    out = script(f'op("file.open", "{p}")\nprint("C", count(), bones("Rig"), weight("Body", 0, 0), weight("Body", 40, 1))\nselect("Rig")\nop("arm.pose", "Bone rot 0 0 60")\nprint("D", evpos("Body", 40, "x")*1000000, evpos("Body", 40, "y")*1000000)\n')
    print('   ', out.strip().replace(chr(10), ' | '))
    port('--op', f'file.open {p}', '--select', 'Rig', '--op', 'arm.pose Bone rot 0 0 60', '--dump-verts', f'{T}/c.txt;Body')
    d = [ln.split() for ln in out.splitlines() if ln.startswith('D ')]
    check(bool(d) and rel(float(d[0][1]) / 1e6, vrt('c', 40, 0)) < 2e-6 and rel(float(d[0][2]) / 1e6, vrt('c', 40, 1)) < 2e-6, 'the character template skins the same in a script')


ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
ROW.update({str(i): i + 1 for i in range(1, 10)})
ENTER, ESC, TAB = 28, 1, 15


def typed(f, s):
    for c in s:
        if c == '_':
            f.key(12, 1)
        elif c == ':':
            f.key(39, 1)
        elif c.isupper():
            f.key(ROW[c.lower()], 1)
        else:
            f.key(ROW[c])


def line(f, s):
    f.key(ENTER)
    f.pump(0.1)
    typed(f, s)
    f.key(ENTER)
    f.key(ESC)
    f.pump(0.25)


def keys(f, s):
    """Words: a key or a typed value; the pointer stays over the viewport."""
    for w in s.split():
        if w == 'enter':
            f.key(ENTER)
        elif w == 'tab':
            f.key(TAB)
        elif w == 'ctrltab':
            f.key(TAB, 4)
            f.pump(0.05)
        else:
            typed(f, w)
        f.pump(0.12)
    f.pump(0.2)


def session(base, steps, save, probe=None):
    """BeeModel in a window, keys and a console line by line; then, through its
    MCP socket (script_eval), what `probe` prints in that window."""
    from wl_fake import Fake
    f = Fake(BIN)
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)
    f.enter(600, 300)
    f.motion(605, 305)
    f.pump(0.3)
    line(f, f'file.open {base}')
    f.pump(0.3)
    for kind, what in steps:
        if kind == 'line':
            line(f, what)
        else:
            f.motion(600, 310)
            f.pump(0.1)
            keys(f, what)
    line(f, f'file.save {save}')
    f.pump(0.3)
    out = Mcp(f).run(probe) if probe else ''
    f.close()
    return out


class Mcp:
    """BeeModel's own socket (docs/MCP.md): scripts into a running window."""

    def __init__(self, f):
        import json
        self.f, self.json, self.i = f, json, 1
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(f.dir + '/beemodel.sock')
        self.s.setblocking(False)
        self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'rig', 'version': '1'}})

    def call(self, m, p):
        self.i += 1
        self.s.send((self.json.dumps({'jsonrpc': '2.0', 'id': self.i, 'method': m, 'params': p}) + '\n').encode())
        b = b''
        for _ in range(1000):
            self.f.pump(0.01)
            try:
                b += self.s.recv(1 << 20)
            except BlockingIOError:
                pass
            if b.endswith(b'\n'):
                break
        return self.json.loads(b)

    def run(self, code):
        r = self.call('tools/call', {'name': 'script_eval', 'arguments': {'code': code}})
        return r['result']['content'][0]['text']


def rig_world(path):
    """Each bone's name, and its tail in the world, from a saved file."""
    o = next(x for x in beefile.objects(path) if x['name'] == 'Rig')
    d = display(path)
    a = beefile.chunk(path, b'ARMT')
    n = struct.unpack_from('<I', a, 4)[0]
    names = [a[64 + i * 128:64 + i * 128 + 24].split(b'\0')[0].decode() for i in range(n)]
    sx, cx = math.sin(o['rot'][0]), math.cos(o['rot'][0])
    sy, cy = math.sin(o['rot'][1]), math.cos(o['rot'][1])
    sz, cz = math.sin(o['rot'][2]), math.cos(o['rot'][2])
    r = [[cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx], [sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx], [-sy, cy * sx, cy * cx]]
    tails = []
    for i in range(n):
        v = d[i * 18 + 3:i * 18 + 6]
        for row in range(3):
            tails.append(sum(r[row][c] * o['scl'][c] * v[c] for c in range(3)) + o['loc'][row])
    return names, tails


def s_modes():
    print('-- edit and pose mode, driven by keys in a window: the window\'s own readouts, the saved file, the skin after reopening --')
    base = scene()
    runs = [('pose: grab', [('line', 'arm.select_bone Upper'), ('keys', 'ctrltab'), ('keys', 'g y 2 enter')]),
            ('pose: rotate', [('line', 'arm.select_bone Upper'), ('keys', 'ctrltab'), ('keys', 'r z 30 enter')]),
            ('pose: rotate a child, posed parent', [('line', 'arm.pose Upper rot 10 20 30'), ('line', 'arm.select_bone Fore'), ('keys', 'ctrltab'), ('keys', 'r x 40 enter')]),
            ('pose: grab a child', [('line', 'arm.pose Upper rot 10 20 30'), ('line', 'arm.select_bone Hand'), ('keys', 'ctrltab'), ('keys', 'g z 1 enter')]),
            ('pose: scale', [('line', 'arm.select_bone Fore'), ('keys', 'ctrltab'), ('keys', 's x 2 enter')]),
            ('pose: two bones, clear', [('line', 'arm.select_bone Upper'), ('line', 'arm.select_bone Side extend'), ('keys', 'ctrltab'), ('keys', 'r y 25 enter'), ('line', 'arm.select_bone Side'), ('keys', 'g x 1 enter')]),
            ('edit: grab', [('line', 'arm.select_bone Fore'), ('keys', 'tab'), ('keys', 'g x 1 enter')]),
            ('edit: rotate', [('line', 'arm.select_bone Hand'), ('keys', 'tab'), ('keys', 'r z 45 enter')]),
            ('edit: scale', [('line', 'arm.select_bone Upper'), ('keys', 'tab'), ('keys', 's y 2 enter')]),
            ('edit: extrude', [('line', 'arm.select_bone Fwd'), ('keys', 'tab'), ('keys', 'e z 1 enter')]),
            ('edit: delete', [('line', 'arm.select_bone Fore'), ('keys', 'tab'), ('keys', 'x')]),
            ('edit: select all, delete nothing', [('line', 'arm.select_bone Fore'), ('keys', 'tab'), ('keys', 'a')]),
            ]
    base_d = display(base)
    names0 = rig_world(base)[0]
    for name, steps in runs:
        q = f'{T}/mp.bee'
        if os.path.exists(q):
            os.unlink(q)
        # (the probe names the bones it may find: the base's, and an extruded one)
        cand = names0 + [n + '.001' for n in names0] + [f'Bone.{k}' for k in range(1, 12)]
        pr = 'print("N", bones("Rig"))\n'
        pr += ''.join(f'if bonepos("Rig", "{n}", "x") != nil {{\n print("B", "{n}", bonepos("Rig", "{n}", "x")*1000000, bonepos("Rig", "{n}", "y")*1000000, bonepos("Rig", "{n}", "z")*1000000)\n' +
                      f' print("P", "{n}", ' + ', '.join(f'prop("bone:Rig:{n}:{c}")*1000000' for c in ('x', 'y', 'z', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz')) + ')\n}\n' for n in cand)
        pr += 'i = 0; while i < 482 { print("V", evpos("Body", i, "x")*1000000, evpos("Body", i, "y")*1000000, evpos("Body", i, "z")*1000000); i = i + 23 }\n'
        out = session(base, steps, q, pr)
        if not os.path.exists(q):
            check(False, f'{name}: the window saved nothing')
            continue
        names, tails = rig_world(q)
        arm_c = beefile.chunk(q, b'ARMT')
        pv = {n: list(struct.unpack_from('<9f', arm_c, 64 + i * 128 + 60)) for i, n in enumerate(names)}
        got = [ln.split() for ln in out.splitlines()]
        nb = [int(float(w[1])) for w in got if w and w[0] == 'N']
        check(nb == [len(names)], f'{name}: {nb} bones in the window, {len(names)} in its file')
        bp = {w[1]: [float(x) / 1e6 for x in w[2:5]] for w in got if w and w[0] == 'B' and len(w) == 5}
        if all(n in bp for n in names):
            compare(f'{name}: tails, the window and its file', [c for n in names for c in bp[n]], tails, 2e-5)
        else:
            check(False, f'{name}: the window does not name the file\'s bones ({names} / {sorted(bp)})')
        wp = {w[1]: [float(x) / 1e6 for x in w[2:]] for w in got if w and w[0] == 'P' and len(w) == 11}
        common = [n for n in names if n in wp]
        compare(f'{name}: poses, the window and its file', [v for n in common for v in wp[n]], [v for n in common for v in pv[n]], 2e-5)
        d = display(q)
        check(len(d) != len(base_d) or max(abs(x - y) for x, y in zip(d, base_d)) > 0.01 or 'nothing' in name, f'{name}: it did something')
        port('--op', f'file.open {q}', '--dump-verts', f'{T}/mv.txt;Body')
        v = [[float.fromhex(x) for x in ln.split()] for ln in open(f'{T}/mv.txt')]
        compare(f'{name}: the skin, in the window and after reopening its file', [float(x) / 1e6 for w in got if w and w[0] == 'V' for x in w[1:]], [c for k in range(0, 482, 23) for c in v[k]], 2e-5)


def s_paths():
    print('-- bone motion paths, the template, the skin in what leaves the program --')
    base = scene()
    a = opened(base, 'Rig') + ops('anim.key bone:Rig:Upper:rz 1 0', 'anim.key bone:Rig:Upper:rz 20 1', 'arm.select_bone Hand')
    r = port(*a, '--key', 'ctrl+tab', '--expect-anim', 'arm_mode=2', '--op', 'anim.motion_paths 1 20', '--expect-anim', 'paths=1')
    check(r.returncode == 0, 'pose mode, a selected bone: one path')
    port(*a, '--key', 'ctrl+tab', '--expect-anim', 'bonesel:Rig=1', '--op', 'anim.motion_paths 1 20', '--dump-paths', f'{T}/mp.txt')
    pts = [[float.fromhex(x) for x in ln.split()] for ln in open(f'{T}/mp.txt')]
    out = script(f'op("file.open", "{base}")\nselect("Rig")\nkey("bone:Rig:Upper:rz", 1, 0)\nkey("bone:Rig:Upper:rz", 20, 1)\n' + ''.join(f'frame({f})\nprint("B", bonepos("Rig", "Hand", "x")*1000000, bonepos("Rig", "Hand", "y")*1000000, bonepos("Rig", "Hand", "z")*1000000)\n' for f in range(1, 21)))
    w = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('B ') for x in ln.split()[1:]]
    compare('the path is the bone\'s tail, frame by frame', w, [c for q in pts for c in q], 3e-6)
    check(len(pts) == 20 and max(abs(pts[0][k] - pts[19][k]) for k in range(3)) > 0.5, f'{len(pts)} points, and they go somewhere')
    # the template (t_character: a script, which a script cannot start): the same script by hand
    script('n = count()\nfor i in 0..n { delete(name(0)) }\na = armature("Rig")\nop("arm.bone", "Spine Bone 0 1 0 0 1.8 0")\nadd("cylinder", "Body", 0, 1, 0)\nscale("Body", 0.4)\nop("arm.parent", "Body Rig")\nselect("Body")\nop("create.light")\nop("create.camera")\n' + f'op("file.save", "{T}/co.bee")\n')
    port('--op', 'help.template character', '--expect-objects', '4', '--op', f'file.save {T}/cp.bee')
    a0, b0 = dict(beefile.chunks(f'{T}/co.bee')), dict(beefile.chunks(f'{T}/cp.bee'))
    check(clean(a0[b'ARMT']) == clean(b0[b'ARMT']) and a0[b'MWGT'][4:] == b0[b'MWGT'][4:], 'help.template character: bones and weights as its script makes them')
    ok_ = [(o['name'], o['type'], o['loc'], o['scl']) for o in beefile.objects(f'{T}/co.bee')]
    pk_ = [(o['name'], o['type'], o['loc'], o['scl']) for o in beefile.objects(f'{T}/cp.bee')]
    check(ok_ == pk_, f'the template and its script: the same objects {ok_ if ok_ != pk_ else ""} {pk_ if ok_ != pk_ else ""}')
    # what leaves: an OBJ of the posed body, not the rest pose
    pose = ops(*[f'arm.pose {b} {w_} {x} {y} {z}' for b, w_, x, y, z in POSE])
    port(*opened(base, 'Rig'), *pose, '--op', f'file.export_obj {T}/x.obj')
    port(*opened(base, 'Rig'), '--op', f'file.export_obj {T}/y.obj')
    rd = lambda n: [[float(c) for c in ln.split()[1:4]] for ln in open(f'{T}/{n}.obj') if ln.startswith('v ')]
    vs, v0 = rd('x'), rd('y')
    check(len(vs) == len(v0) and len(vs) > 482 and max(abs(a_ - b_) for p_, q_ in zip(vs, v0) for a_, b_ in zip(p_, q_)) > 0.3, f'the export has the pose ({len(vs)} vertices)')
    check(not any(ln.startswith(('o Rig', 'g Rig')) for ln in open(f'{T}/x.obj')), 'the armature is not exported')
    # F12: the pose changes the picture
    os.makedirs(f'{T}/rn', exist_ok=True)
    for k, pre in enumerate(([], pose)):
        port(*opened(base, 'Rig'), *ops('render.settings 96 64 4'), *pre, '--op', f'render.animation {T}/rn/r{k}.png 1 1')
    fs = [f'{T}/rn/r{k}/0001.png' for k in (0, 1)]
    pics = [open(x, 'rb').read() if os.path.exists(x) else b'' for x in fs]
    check(bool(pics[0]) and bool(pics[1]) and pics[0] != pics[1], 'F12 renders the skin as posed')
    # Rendered shading: the same
    shots = []
    for pre in ([], pose):
        port(*opened(base, 'Rig'), '--size', '320x240', *pre, '--op', 'view.shading_rendered', '--live-wait')
        shots.append(open(f'{T}/u.ppm', 'rb').read())
    check(shots[0] != shots[1] and len(shots[0]) > 1000, 'Rendered shows the skin as posed')
    # on every core: a mesh past one chunk of the job (4096 vertices)
    if (os.cpu_count() or 1) > 1:
        r = port('--op', 'help.template character', '--select', 'Body', *ops('object.modifier_remove 0', 'object.modifier_add subsurf', 'object.modifier_set 0 levels 5', 'object.modifier_apply 0'), '--wait', '100',
                 *ops('arm.parent Body Rig'), '--select', 'Rig', *ops(*[f'arm.pose Spine rot 0 0 {k * 9}' for k in range(1, 7)]), '--dump-verts', f'{T}/par.txt;Body', '--expect-anim', 'skin_parallel=1', ok=False)
        n = sum(1 for _ in open(f'{T}/par.txt'))
        check(r.returncode == 0 and n > 4096 * 2, f'{n} vertices skinned on more than one thread')


def s_undo():
    print('-- undo: a step a change, the bones and the skin back --')
    base = scene()
    a = opened(base, 'Rig')
    port(*a, '--dump-rig', f'{T}/u0.txt;Rig', '--dump-verts', f'{T}/u0v.txt;Body', '--op', 'arm.pose Upper rot 0 0 70', '--dump-rig', f'{T}/u1.txt;Rig', '--dump-verts', f'{T}/u1v.txt;Body',
         '--expect-anim', 'undo=1', '--op', 'arm.pose Fore rot 30 0 0', '--expect-anim', 'undo=2', '--key', 'ctrl+z', '--key', 'ctrl+z', '--expect-anim', 'undo=0', '--dump-rig', f'{T}/u2.txt;Rig', '--dump-verts', f'{T}/u2v.txt;Body',
         '--key', 'ctrl+shift+z', '--dump-rig', f'{T}/u3.txt;Rig', '--dump-verts', f'{T}/u3v.txt;Body', '--op', 'constraint.add Rig:Hand ik Goal chain 2', '--expect-anim', 'constraints=1', '--key', 'ctrl+z', '--expect-anim', 'constraints=0', '--dump-rig', f'{T}/u4.txt;Rig')
    t = lambda n: open(f'{T}/{n}.txt').read()
    check(t('u0') != t('u1') and t('u0v') != t('u1v'), 'the pose moved bones and skin')
    check(t('u0') == t('u2') and t('u0v') == t('u2v'), 'undo: as they were, to the bit')
    check(t('u1') == t('u3') and t('u1v') == t('u3v'), 'redo: the same')
    check(t('u1') == t('u4'), 'the last IK undone: the bones lose it')
    r = port(*a, '--move', '615,360', '--key', 'tab', '--expect-anim', 'arm_mode=1', '--op', 'arm.select_all', '--key', 'g', '--key', 'x', '--type', '1', '--key', 'esc', '--expect-anim', 'undo=0', '--key', 'g', '--key', 'x', '--type', '1', '--key', 'enter', '--expect-anim', 'undo=1')
    check(r.returncode == 0, 'a cancelled transform is no step, a confirmed one is one')


def s_eval_undo():
    print('-- undo and evaluation: an edit is its own step, evaluated values stay out of the step before --')
    G = ['--move', '500,300', '--key', 'g', '--key', 'x', '--type', '2', '--key', 'enter']
    C = ['--op', 'create.cube', '--select', 'Cube']
    E = lambda *w: [x for s in w for x in ('--expect-anim', s)]

    def case(name, *a):
        r = port(*a, ok=False)
        check(r.returncode == 0, f'{name} {r.stderr[-260:].strip()}')

    def recs(p):
        return {o['name']: (o['loc'], o['rot'], o['scl']) for o in beefile.objects(p)}

    def same(name, *a):
        """Saved before and after: the scene's transforms to the bit."""
        for f in ('eu0', 'eu1'):
            if os.path.exists(f'{T}/{f}.bee'):
                os.unlink(f'{T}/{f}.bee')
        i = a.index('EDIT')
        r = port(*a[:i], '--op', f'file.save {T}/eu0.bee', *a[i + 1:], '--op', f'file.save {T}/eu1.bee', ok=False)
        check(r.returncode == 0 and recs(f'{T}/eu0.bee') == recs(f'{T}/eu1.bee'), f'{name} {r.stderr[-260:].strip()}')

    trk = C + ['--op', 'constraint.add Cube track_to Cube.001', '--select', 'Cube']
    same('a move, tracking: undone, every transform as it was', *trk, 'EDIT', *G, *E('Cube:x=2'), '--op', 'edit.undo', *E('Cube:x=0'))
    case('a move, tracking: a step, redone', *trk, *E('undo=2'), *G, *E('undo=3', 'Cube:x=2'), '--op', 'edit.undo', *E('undo=2', 'Cube:x=0'), '--op', 'edit.redo', *E('undo=3', 'Cube:x=2'))
    lim = ['--select', 'Cube', '--op', 'constraint.add Cube limit_location axes x min -1 0 0 max 1 0 0']
    case('a move past a limit: undone', *lim, *G, *E('undo=2', 'Cube:x=1'), '--op', 'edit.undo', *E('undo=1', 'Cube:x=0'), '--op', 'edit.redo', *E('undo=2', 'Cube:x=1'))
    case('a cancelled move, limited: nothing', *lim, '--move', '500,300', '--key', 'g', '--key', 'x', '--type', '2', '--key', 'esc', *E('undo=1', 'Cube:x=0'))
    case('a cancelled move, tracking: nothing', *trk, '--move', '500,300', '--key', 'g', '--key', 'x', '--type', '2', '--key', 'esc', *E('undo=2', 'Cube:x=0'))
    drv = ['--select', 'Cube', '--op', 'anim.driver Cube:y a=Cube:x a*2']
    case('a move, the object driving itself: undone', *drv, *G, *E('undo=2', 'Cube:x=2', 'Cube:y=4'), '--op', 'edit.undo', *E('undo=1', 'Cube:x=0', 'Cube:y=0'))
    case('an operator on a driven object: its step',
         '--select', 'Cube', '--op', 'move 0.3 0 0', '--op', 'anim.driver Cube:y a=Cube:x a*2', *E('undo=2', 'Cube:y=0.6'), '--op', 'object.to_grid', *E('undo=3', 'Cube:x=0', 'Cube:y=0'),
         '--op', 'edit.undo', *E('undo=2', 'drivers=1', 'Cube:x=0.3', 'Cube:y=0.6'))
    # a field dragged: the widget's place from the window's dump
    port('--size', '1400x900', '--select', 'Cube')
    x, y = next(tuple(map(int, ln.split('\t')[2].split()[:2])) for ln in open(f'{T}/u.txt') if ln.startswith('number'))
    d = ['--size', '1400x900', *lim, '--drag', f'{x + 20},{y + 8},{x + 220},{y + 8}']
    case('a field dragged past a limit: its step, undone', *d, *E('undo=2', 'Cube:x=1'), '--op', 'edit.undo', *E('undo=1', 'drivers=0', 'constraints=1', 'Cube:x=0'))
    cp = ['--op', 'create.cube', '--op', 'move 3 0 0', '--select', 'Cube', '--op', 'constraint.add Cube copy_location Cube.001 influence 0.5', '--op', 'anim.frame 2', *E('Cube:x=1.5')]
    case('an influence undone: the value before, the base kept', *cp, '--op', 'constraint.set 1 influence 0.25', '--op', 'anim.frame 2', *E('Cube:x=0.75'), '--op', 'edit.undo', '--op', 'anim.frame 2', *E('Cube:x=1.5'))
    case('a removed constraint undone', *cp, '--op', 'constraint.remove 1', *E('Cube:x=0'), '--op', 'edit.undo', '--op', 'anim.frame 2', *E('constraints=1', 'Cube:x=1.5'))
    case('a muted constraint undone', *cp, '--op', 'constraint.set 1 mute 1', '--op', 'anim.frame 2', *E('Cube:x=0'), '--op', 'edit.undo', '--op', 'anim.frame 2', *E('Cube:x=1.5'))
    case('a second constraint undone',
         *lim, '--op', 'move 0.5 0 0', '--op', 'anim.frame 2', *E('Cube:x=0.5'), '--op', 'create.cube', '--op', 'move 3 0 0', '--select', 'Cube',
         '--op', 'constraint.add Cube copy_location Cube.001 influence 0.5', '--op', 'anim.frame 2', *E('Cube:x=1.75'), '--op', 'edit.undo', '--op', 'anim.frame 2', *E('constraints=1', 'Cube:x=0.5'))
    # what the old absorb also took along: the modifiers, the mesh
    case('a modifier value with a driver on it: its step, undone',
         '--select', 'Cube', '--op', 'object.modifier_add subsurf', '--op', 'object.modifier_set 0 levels 1', '--op', 'anim.driver Cube:y a=modifier:Cube:0:levels a*2', *E('undo=3', 'Cube:y=2'),
         '--op', 'object.modifier_set 0 levels 2', *E('undo=4', 'modifier:Cube:0:levels=2', 'Cube:y=4'), '--op', 'edit.undo', *E('undo=3', 'modifier:Cube:0:levels=1', 'Cube:y=2'))
    case('a shape value with a driver on the mesh object: its step, undone',
         '--op', 'create.sphere', '--op', 'shape.add Smile Sphere', '--op', 'anim.driver Sphere:y a=shape:Sphere:Smile a*2', *E('undo=3', 'Sphere:y=0'),
         '--op', 'shape.set Smile 0.5 Sphere', *E('undo=4', 'shape:Sphere:Smile=0.5', 'Sphere:y=1'), '--op', 'edit.undo', *E('undo=3', 'shape:Sphere:Smile=0', 'Sphere:y=0'))
    # what absorb was for: evaluated values are no steps, and a step holds them
    k = ['--op', 'create.cube', '--op', 'anim.key Cube.001:x 1 0', '--op', 'anim.key Cube.001:x 25 4', '--select', 'Cube', '--op', 'constraint.add Cube copy_location Cube.001 axes x']
    case('frames, a constraint following: no steps; a step undoes to that frame', *k, *E('undo=4'), '--op', 'anim.frame 25', '--op', 'anim.frame 13', '--op', 'anim.frame 25', *E('undo=4', 'Cube:x=4'),
         '--op', 'move 4 0 1', *E('undo=5', 'Cube:z=1'), '--op', 'edit.undo', *E('undo=4', 'Cube:x=4', 'Cube:z=0'))
    case('a child at a frame undoes to that frame', '--op', 'create.cube', '--op', 'object.parent_set Cube.001 Cube', '--op', 'anim.key Cube.001:x 1 1', '--op', 'anim.key Cube.001:x 25 2', '--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 3',
         '--op', 'anim.frame 25', *E('undo=6', 'Cube.001:x=5', 'Cube:x=3'), '--select', 'Cube', '--op', 'object.modifier_add subsurf', *E('undo=7'), '--op', 'edit.undo', *E('undo=6', 'Cube.001:x=5', 'Cube:x=3'))


def s_undo_keys():
    print('-- undo past keys: a frame leaves the steps\' bones alone --')
    E = lambda *w: [x for s in w for x in ('--expect-anim', s)]
    base = scene()
    a = opened(base, 'Rig')
    pose = ['--op', 'arm.pose Upper rot 0 0 10', *E('bone:Rig:Upper:rz=0.1745')]
    keys = ['--op', 'anim.key bone:Rig:Upper:rz 1 0.1', '--op', 'anim.key bone:Rig:Upper:rz 25 1', '--op', 'anim.frame 25', *E('bone:Rig:Upper:rz=1')]
    r = port(*a, *pose, '--dump-verts', f'{T}/k0.txt;Body', '--dump-rig', f'{T}/k0r.txt;Rig', *keys, '--dump-verts', f'{T}/k1.txt;Body', *E('undo=3'), '--op', 'edit.undo', '--op', 'edit.undo', *E('curves=0', 'bone:Rig:Upper:rz=0.1745'),
             '--dump-verts', f'{T}/k2.txt;Body', '--dump-rig', f'{T}/k2r.txt;Rig', '--op', f'file.save {T}/k.bee', '--op', 'edit.redo', '--op', 'edit.redo', *E('curves=1', 'bone:Rig:Upper:rz=1'), '--dump-verts', f'{T}/k3.txt;Body', ok=False)
    check(r.returncode == 0, f'the pose from before its keys comes back {r.stderr[-260:].strip()}')
    t = lambda n: open(f'{T}/{n}.txt').read()
    check(t('k0') != t('k1'), 'the keys moved the skin')
    check(t('k0') == t('k2') and t('k0r') == t('k2r'), 'undone: bones and skin as they were, to the bit')
    check(t('k1') == t('k3'), 'redone: the frame\'s pose')
    r = port('--op', f'file.open {T}/k.bee', *E('bone:Rig:Upper:rz=0.1745'), ok=False)
    check(r.returncode == 0, f'saved after the undo: the pose from before {r.stderr[-200:].strip()}')
    # a frame while another object is being moved: the step before keeps its bones
    r = port(*a, *pose, *keys, '--op', 'anim.frame 13', '--print-anim', 'bone:Rig:Upper:rz', '--select', 'Goal', '--move', '500,300', '--key', 'g', '--key', 'x', '--type', '2', '--move', '640,300', '--bench', '1',
             '--op', 'anim.frame 25', '--key', 'enter', *E('bone:Rig:Upper:rz=1'), '--op', 'edit.undo', '--print-anim', 'bone:Rig:Upper:rz', ok=False)
    v = re.findall(r'rz=([-\d.e]+)', r.stderr)
    check(r.returncode == 0 and len(v) == 2 and v[0] == v[1] and float(v[0]) != 1, f'undone: the pose at the frame before the move {v} {r.stderr[-200:].strip()}')
    # a copy at the first write, none at the frames after it
    r = port(*a, *pose, *keys, '--op', 'anim.frame 2', '--print-anim', 'meshes', '--op', 'anim.frame 3', '--op', 'anim.frame 4', '--op', 'anim.frame 5', '--op', 'anim.frame 6', '--print-anim', 'meshes', ok=False)
    m = re.findall(r'meshes=(\d+)', r.stderr)
    check(len(m) == 2 and m[0] == m[1], f'frames after the first copy no mesh: {m}')


def s_forms():
    print('-- the forms through the window: Object is a text field, Target starts empty --')
    S = ['--size', '1400x1500']
    r = port('--op', 'create.armature Arm', '--op', 'arm.bone Upper Bone 0 1 0 0 2 0', '--op', 'create.cube', '--select', 'Arm', *S, '--click-label', 'tab:Rig', '--click-label', 'Add Constraint...',
             '--expect-label', 'text:Arm', '--expect-label', 'text:Target',
             '--click-label', 'text:Arm', '--type', 'Arm:Upper', '--key', 'enter',
             '--click-label', 'Copy Location', '--click-label', 'IK',
             '--click-label', 'text:Target', '--type', 'Cube.001', '--key', 'enter', '--click-label', 'OK',
             '--expect-anim', 'constraints=1', '--op', 'constraint.list', ok=False)
    log = open(f'{T}/log.txt').read()
    check(r.returncode == 0 and 'ik on Arm:Upper -> Cube.001' in log, f'IK on a bone from the form {r.stderr[-260:].strip()}')
    for lab, word in (('Limit Location', 'limit_location'), ('Limit Rotation', 'limit_rotation'), ('Limit Scale', 'limit_scale')):
        r = port('--select', 'Cube', *S, '--click-label', 'tab:Rig', '--click-label', 'Add Constraint...', '--click-label', 'Copy Location', '--click-label', lab, '--click-label', 'OK', '--expect-anim', 'constraints=1', '--op', 'constraint.list', ok=False)
        check(r.returncode == 0 and f'{word} on Cube' in open(f'{T}/log.txt').read(), f'{lab} from the form, its Target left empty {r.stderr[-260:].strip()}')
    # the active object's name each time; another object can be typed
    r = port('--op', 'create.cube', '--select', 'Cube', *S, '--click-label', 'tab:Rig', '--click-label', 'Add Constraint...', '--click-label', 'text:Cube', '--type', 'Light', '--key', 'enter',
             '--click-label', 'text:Target', '--type', 'Cube.001', '--key', 'enter', '--click-label', 'OK', '--op', 'constraint.list', ok=False)
    check(r.returncode == 0 and 'copy_location on Light -> Cube.001' in open(f'{T}/log.txt').read(), f'the Object typed {r.stderr[-260:].strip()}')
    # anim.layer: an object typed, and - for the objects it was keyed on
    keyed = ['--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 4', '--select', 'Cube', '--op', 'anim.action Action', '--op', 'create.cube', '--select', 'Cube', '--op', 'anim.frame 13']
    for what, typed, chan, val in (('the object typed', 'Cube.001', 'Cube.001:x', 2), ('- : where it was keyed', '-', 'Cube:x', 2)):
        r = port(*keyed, *S, '--click-label', 'tab:Animation', '--click-label', 'Add Layer...', '--click-label', 'text:Cube', '--type', typed, '--key', 'enter', '--click-label', 'OK',
                 '--expect-anim', 'layers=1', '--op', 'anim.frame 13', '--expect-anim', f'{chan}={val}', ok=False)
        check(r.returncode == 0, f'Add Layer: {what} {r.stderr[-260:].strip()}')
    # a field left with a click keeps what was typed; an Object emptied keeps its place: "-"
    r = port('--op', 'create.cube', '--select', 'Cube', *S, '--click-label', 'tab:Rig', '--click-label', 'Add Constraint...', '--click-label', 'text:Cube', '--type', 'Light', '--click-label', 'text:Target', '--type', 'Cube.001', '--click-label', 'OK', '--op', 'constraint.list', ok=False)
    check(r.returncode == 0 and 'copy_location on Light -> Cube.001' in open(f'{T}/log.txt').read(), f'typed, then a click on the next field {r.stderr[-260:].strip()}')
    r = port(*keyed, *S, '--click-label', 'tab:Animation', '--click-label', 'Add Layer...', '--click-label', 'text:Cube', '--key', 'backspace', '--key', 'enter', '--click-label', 'OK', '--expect-anim', 'layers=1', ok=False)
    check(r.returncode == 0, f'Add Layer, the Object emptied {r.stderr[-260:].strip()}')
    r = port('--op', 'create.armature Arm', '--op', 'create.sphere', '--select', 'Sphere', *S, '--click-label', 'tab:Rig', '--click-label', 'Parent to Armature...', '--expect-label', 'text:Armature', '--click-label', 'text:Armature', '--type', 'Arm', '--key', 'enter', '--click-label', 'OK',
             '--expect-anim', 'weights:Sphere=482', ok=False)
    check(r.returncode == 0, f'Parent to Armature from the form {r.stderr[-260:].strip()}')


def s_stack():
    print('-- the stack: off, its mode, what comes before and after it --')
    base = scene()
    pr = 'i = 0; while i < 482 { print("V", evpos("Body", i, "x")*1000000, evpos("Body", i, "y")*1000000, evpos("Body", i, "z")*1000000); i = i + 37 }\n'
    rd = lambda out: [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('V ') for x in ln.split()[1:]]
    pose = 'arm.pose Upper rot 0 0 50'
    for name, oo, pp in (
            ('off', 'select("Body")\nop("object.modifier_toggle", "0")\n', ['--select', 'Body', '--op', 'object.modifier_toggle 0']),
            ('dual by a value', 'select("Body")\nmodset("Body", 0, "mode", 1)\n', ['--select', 'Body', '--op', 'object.modifier_set 0 mode 1']),
            ('after a mirror: no weights there', 'select("Body")\nop("object.modifier_add", "mirror")\nop("object.modifier_move_up", "1")\n', ['--select', 'Body', '--op', 'object.modifier_add mirror', '--op', 'object.modifier_move_up 1']),
            ('before a subsurf', 'select("Body")\nop("object.modifier_add", "subsurf")\n', ['--select', 'Body', '--op', 'object.modifier_add subsurf'])):
        out = script(f'op("file.open", "{base}")\nselect("Rig")\nop("arm.pose", "{pose.split(" ", 1)[1]}")\n{oo}{pr}')
        w = rd(out)
        port(*opened(base, 'Rig'), '--op', pose, *pp, '--dump-verts', f'{T}/st.txt;Body')
        v = [[float.fromhex(x) for x in ln.split()] for ln in open(f'{T}/st.txt')]
        compare(name, w, [c for k in range(0, 482, 37) if k < len(v) for c in v[k]], 2e-6)
    # applied: the mesh keeps the pose and its weights
    r = port(*opened(base, 'Body'), '--op', 'object.modifier_apply 0', '--wait', '50', '--expect-anim', 'weights:Body=482', ok=False)
    check(r.returncode == 0, 'applied: the weights stay on the mesh')


def flip(b, rng, lo, hi):
    for _ in range(rng.choice((1, 2, 8, 32))):
        o = rng.randrange(lo, hi)
        w = rng.choice((0xffffffff, 0x7fc00000, 0x7f800000, 0xff800000, 0x80000000, 0x40000000, rng.getrandbits(32), 129, 1 << 20))
        struct.pack_into('<I', b, o & ~3, w)


def s_damage():
    print(f'-- damaged chunks ({RUNS} files, then each field by hand) --')
    rng = random.Random(SEED)
    base = scene()
    src = f'{T}/dm.bee'
    port(*opened(base, 'Rig'), *ops('constraint.add Rig:Hand ik Goal chain 3 pole Pole', 'constraint.add Pole track_to Goal', 'anim.key bone:Rig:Upper:rz 1 0', 'anim.key bone:Rig:Upper:rz 9 1', f'file.save {src}'))
    d0 = open(src, 'rb').read()
    where = {}
    o = 8
    while o + 8 <= len(d0):
        tag, size = d0[o:o + 4], struct.unpack_from('<I', d0, o + 4)[0]
        where.setdefault(tag, []).append((o + 8, size))
        o += 8 + size
    arm0, armn = where[b'ARMT'][0]
    wg0, wgn = where[b'MWGT'][0]
    an0, ann = where[b'ANIM'][0]
    md0, mdn = where[b'MODS'][0]
    con = an0 + 35392 + 4
    crashed = 0

    def run(b, name):
        nonlocal crashed
        p = f'{T}/dd.bee'
        open(p, 'wb').write(b)
        r = port('--op', f'file.open {p}', '--select', 'Rig', '--op', 'arm.pose Upper rot 10 20 30', '--op', 'anim.frame 5', '--op', 'arm.auto_weights Body', '--dump-verts', f'{T}/dv.txt;Body', '--dump-rig', f'{T}/dr.txt;Rig', '--op', f'file.save {T}/dd2.bee', ok=False)
        if r.returncode != 0:
            crashed += 1
            print(f'  crash ({r.returncode}) on {name}: kept {p}.{crashed}; {r.stderr[-400:]}')
            open(f'{p}.{crashed}', 'wb').write(b)
    for k in range(RUNS):
        b = bytearray(d0)
        which = k % 4
        if which == 0:
            flip(b, rng, arm0, arm0 + armn)
        elif which == 1:
            flip(b, rng, wg0, wg0 + wgn)
        elif which == 2:
            flip(b, rng, con, con + 3 * 192)
        else:
            flip(b, rng, md0, md0 + mdn)
            flip(b, rng, arm0, arm0 + 200)
        run(b, f'random {k}')
    bn = arm0 + 64  # the first bone
    cases = [('bones 129', arm0 + 4, 129), ('bones huge', arm0 + 4, 0xffffffff), ('active bone huge', arm0 + 8, 0x7fffffff), ('mesh index huge', arm0, 0x7fffffff), ('a parent ahead', bn + 128 + 24, 200), ('a parent below', bn + 128 + 24, 0x80000000),
             ('a NaN head', bn + 28, 0x7fc00000), ('an inf tail', bn + 40, 0x7f800000), ('a NaN pose', bn + 72, 0x7fc00000), ('zero scale', bn + 84, 0), ('a huge head', bn + 28, 0x7f000000),
             ('weights count', wg0 + 4, 0xffffffff), ('weights count off', wg0 + 4, 3), ('weights mesh', wg0, 0x7fffffff), ('a bone number', wg0 + 8, 0x7f7f7f7f), ('a NaN weight', wg0 + 12, 0x7fc00000), ('an inf weight', wg0 + 16, 0x7f800000),
             ('constraint type', con + 8, 0xffffffff), ('ik bone', con + 4, 0x7fffffff), ('chain', con + 36, 0xffffffff), ('iterations', con + 40, 0xfffffff0), ('influence NaN', con + 32, 0x7fc00000), ('target gone', con + 12, 0x7ffffff), ('track', con + 192 + 24, 0xffffffff), ('up', con + 192 + 28, 0xffffffff), ('limit NaN', con + 192 + 48, 0x7fc00000)]
    for name, at, v in cases:
        b = bytearray(d0)
        struct.pack_into('<I', b, at, v)
        run(b, name)
    for name, tag in (('ARMT', arm0), ('MWGT', wg0)):
        o = tag - 8
        size = struct.unpack_from('<I', d0, o + 4)[0]
        b = bytearray(d0)
        struct.pack_into('<I', b, o + 4, size - 7)
        del b[o + 8 + size - 7:o + 8 + size]
        run(b, f'{name} short')
    check(crashed == 0, f'{RUNS + len(cases) + 2} damaged files: {crashed} crashes')
    # the damage is refused, not swallowed
    b = bytearray(d0)
    struct.pack_into('<I', b, arm0 + 4, 129)
    open(f'{T}/dd.bee', 'wb').write(b)
    q = f'{T}/dq.txt'
    if os.path.exists(q):
        os.unlink(q)
    port('--op', f'file.open {T}/dd.bee', '--dump-rig', f'{q};Rig', ok=False)
    check(not os.path.exists(q) or os.path.getsize(q) == 0, '129 bones: no bones')
    b = bytearray(d0)
    struct.pack_into('<f', b, bn + 28, float('nan'))
    open(f'{T}/dd.bee', 'wb').write(b)
    port('--op', f'file.open {T}/dd.bee', '--dump-rig', f'{q};Rig', ok=False)
    check(os.path.getsize(q) > 0 and 'nan' not in open(q).read(), 'a NaN in a bone goes no further')


def s_window():
    print('-- in a window: an idle rig draws nothing, playback skins --')
    from wl_fake import Fake
    base = scene()
    f = Fake(BIN)
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)
    f.enter(600, 300)
    f.motion(605, 305)
    f.pump(0.3)
    line(f, f'file.open {base}')
    line(f, 'constraint.add Rig:Hand ik Goal chain 3')
    line(f, 'constraint.add Pole track_to Goal')
    line(f, 'anim.key bone:Rig:Upper:rz 1 0')
    line(f, 'anim.key bone:Rig:Upper:rz 25 1')

    def still():
        last = -1
        for _ in range(40):
            f.pump(0.1)
            if f.frames == last:
                break
            last = f.frames
    still()
    n = f.frames
    f.pump(1.2)
    check(f.frames == n, f'constraints, IK, skin, not playing: {f.frames - n} frames in 1.2 s')
    line(f, 'anim.play')
    n = f.frames
    f.pump(1.0)
    check(12 <= f.frames - n <= 40, f'playing: {f.frames - n} frames in a second')
    line(f, 'anim.play')
    still()
    n = f.frames
    f.pump(1.2)
    check(f.frames == n, f'paused: {f.frames - n} frames in 1.2 s')
    f.close()


def patched(src, dst, at):
    """A file with ARMT changed: at(bytearray, offset of the block's bones)."""
    d = bytearray(open(src, 'rb').read())
    if d[4] != 1:
        c = beefile.chunks(src)
        d = bytearray(b'BEEM' + struct.pack('<I', 1))
        for t, b in c:
            d += t + struct.pack('<I', len(b)) + b
    o = 8
    while o + 8 <= len(d):
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if tag == b'ARMT':
            at(d, o + 8 + 64)
        o += 8 + size
    open(dst, 'wb').write(d)


def s_roll():
    print('-- roll, and a bone along Z: only files make them --')
    base = scene()
    p = f'{T}/roll.bee'

    def at(d, b):
        for k, r in enumerate((0.7, -1.1, 2.4, 0.3, -0.5)):
            struct.pack_into('<f', d, b + k * 128 + 52, r)
    patched(base, p, at)
    o = f'{T}/ro.bee'
    q = f'{T}/rp.bee'
    pose = [f'arm.pose {b} {w} {x} {y} {z}' for b, w, x, y, z in POSE]
    code = f'op("file.open", "{p}")\nselect("Rig")\n' + ''.join(f'op("arm.pose", "{ln.split(" ", 1)[1]}")\n' for ln in pose) + f'op("file.save", "{o}")\n'
    out = script(code + 'i = 0; while i < 482 { print("V", evpos("Body", i, "y")*1000000); i = i + 11 }\n')
    w = [float(ln.split()[1]) / 1e6 for ln in out.splitlines() if ln.startswith('V ')]
    port('--op', f'file.open {p}', '--select', 'Rig', *ops(*pose, f'file.save {q}'), '--dump-verts', f'{T}/rv.txt;Body')
    v = [float.fromhex(ln.split()[1]) for ln in open(f'{T}/rv.txt')]
    compare('rolled bones: matrices', display(o), display(q), 1e-6)
    compare('rolled bones: the skin', w, v[::11], 2e-6)
    p0 = f'{T}/rn.bee'
    script(code.replace(p, base).replace(o, p0))
    check(max(abs(x - y) for x, y in zip(display(o), display(p0))) > 0.05, 'the roll changed the bones')


def s_weights():
    print('-- weights that do not add up, point nowhere, or are not there: from a file --')
    base = scene()
    p = f'{T}/wg.bee'
    d = bytearray(open(base, 'rb').read())
    if d[4] != 1:
        d = bytearray(b'BEEM' + struct.pack('<I', 1) + b''.join(t + struct.pack('<I', len(b)) + b for t, b in beefile.chunks(base)))
    o = 8
    while o + 8 <= len(d):
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if tag == b'MWGT':
            q, end = o + 8, o + 8 + size
            while q < end:
                nv = struct.unpack_from('<I', d, q + 4)[0]
                for v in range(nv):
                    r = q + 8 + v * 20
                    if v % 3 == 0:  # half of each: the sum is no longer 1
                        for c in range(4):
                            struct.pack_into('<f', d, r + 4 + c * 4, struct.unpack_from('<f', d, r + 4 + c * 4)[0] * 0.5)
                    elif v % 3 == 1:  # a bone that is not there, a negative weight
                        d[r] = 200
                        struct.pack_into('<f', d, r + 8, -0.3)
                    elif v % 7 == 0:  # nothing
                        struct.pack_into('<4f', d, r + 4, 0, 0, 0, 0)
                q += 8 + nv * 20
        o += 8 + size
    open(p, 'wb').write(d)
    pose = [f'arm.pose {b} {w} {x} {y} {z}' for b, w, x, y, z in POSE]
    code = f'op("file.open", "{p}")\nselect("Rig")\n' + ''.join(f'op("arm.pose", "{ln.split(" ", 1)[1]}")\n' for ln in pose)
    code += ''.join(f'i = 0; while i < {n} {{ print("V", evpos("{m}", i, "x")*1000000, evpos("{m}", i, "y")*1000000, evpos("{m}", i, "z")*1000000); i = i + 1 }}\n' for m, n in (('Body', 482), ('Limb', 64)))
    w = [float(x) / 1e6 for ln in script(code).splitlines() if ln.startswith('V ') for x in ln.split()[1:]]
    port('--op', f'file.open {p}', '--select', 'Rig', *ops(*pose), '--dump-verts', f'{T}/wb.txt;Body', '--dump-verts', f'{T}/wl.txt;Limb')
    g = [float.fromhex(x) for n in ('wb', 'wl') for ln in open(f'{T}/{n}.txt') for x in ln.split()]
    compare('uneven weights: linear blend, dual quaternion', w, g)
    # weights stay while the vertices do; a new topology has none
    # (edit mode starts with every vertex selected: mesh.select_all would toggle them off)
    q = f'{T}/ed.bee'
    script(f'op("file.open", "{base}")\nselect("Body")\nop("mode.toggle_edit")\nop("mesh.subdivide")\nop("mode.toggle_edit")\nselect("Limb")\nop("file.save", "{q}")\n')
    left = len(recs(beefile.chunk(q, b'MWGT')))
    r = port('--op', f'file.open {base}', '--select', 'Body', '--move', '615,360', '--key', 'tab', '--key', '3', *ops('mesh.subdivide'), '--key', 'tab', '--expect-anim', 'weights:Body=0', '--expect-anim', 'weights:Limb=64', ok=False)
    check(left == 1 and r.returncode == 0, f'subdivided: the mesh has no weights any more, the other keeps them (in a script too: {left} left)')


def s_dual():
    print('-- dual quaternions past half a turn: the hemisphere --')
    base = scene()
    o = f'op("file.open", "{base}")\nselect("Rig")\nop("arm.pose", "Upper rot 0 0 170")\nop("arm.pose", "Fore rot 0 0 170")\nop("arm.pose", "Hand rot 0 0 170")\nop("arm.pose", "Side rot 0 175 0")\n'
    out = script(o + 'i = 0; while i < 64 { print("V", evpos("Limb", i, "x")*1000000, evpos("Limb", i, "y")*1000000, evpos("Limb", i, "z")*1000000); i = i + 1 }\n')
    w = [float(x) / 1e6 for ln in out.splitlines() if ln.startswith('V ') for x in ln.split()[1:]]
    port(*opened(base, 'Rig'), *ops('arm.pose Upper rot 0 0 170', 'arm.pose Fore rot 0 0 170', 'arm.pose Hand rot 0 0 170', 'arm.pose Side rot 0 175 0'), '--dump-verts', f'{T}/dv.txt;Limb')
    g = [float.fromhex(x) for ln in open(f'{T}/dv.txt') for x in ln.split()]
    compare('two bones half a turn apart', w, g)


def s_delete():
    print('-- deleting a bone: children and weights follow, a script and the command line alike --')
    base = scene()
    code = f'op("file.open", "{base}")\nselect("Rig")\nop("mode.toggle_edit")\nop("arm.select_bone", "Fore")\nop("arm.delete_bones")\nop("mode.toggle_edit")\nop("arm.pose", "Upper rot 0 0 40")\nop("arm.pose", "Hand rot 30 0 0")\nop("file.save", "{T}/do.bee")\n'
    script(code)
    port(*opened(base, 'Rig'), '--move', '615,360', '--key', 'tab', '--expect-anim', 'arm_mode=1', *ops('arm.select_bone Fore', 'arm.delete_bones', 'mode.toggle_edit', 'arm.pose Upper rot 0 0 40', 'arm.pose Hand rot 30 0 0', f'file.save {T}/dp.bee'))
    a, b = dict(beefile.chunks(f'{T}/do.bee')), dict(beefile.chunks(f'{T}/dp.bee'))
    check(struct.unpack_from('<I', a[b'ARMT'], 4)[0] == 5, 'the script lost a bone')
    check(clean(a[b'ARMT']) == clean(b[b'ARMT']), 'ARMT: the same bones')
    check(recs(a[b'MWGT']) == recs(b[b'MWGT']) and len(recs(a[b'MWGT'])) == 2, 'MWGT: renumbered the same')


def main():
    print(f'seed {SEED}')
    only = os.environ.get('RIG_ONLY', '')
    for s in (s_pose, s_roll, s_weights, s_dual, s_delete, s_keyed, s_ik, s_constraints, s_heat, s_files, s_modes, s_paths, s_undo, s_eval_undo, s_undo_keys, s_forms, s_stack, s_damage, s_window):
        if not only or s.__name__ in only.split(','):
            s()
    print('fails', len(FAILS))
    sys.exit(1 if FAILS else 0)


main()
