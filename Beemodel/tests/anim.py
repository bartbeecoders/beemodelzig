#!/usr/bin/env python3
"""The animation: every channel kind sampled at many frames, in all
interpolation modes, with handles, actions, layers, drivers and shape keys;
the same scene made by a BeeScript script and by console operators gives the
same values; files saved by either read back with the same values, ANIM and
MSHK written again byte for byte; damaged chunks; undo.

    python3 tests/anim.py BIN [damage-runs=120] [seed]
"""
import math, os, random, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 120
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
FAILS = []
T = tempfile.mkdtemp(prefix='beeanim-', dir=os.environ.get('BEERIG_TMP', '/tmp'))
TOL = 2e-6  # (a script prints value * 1e6; a rotation goes through degrees: 2e-7 of 2 rad, floats' ulps)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def script(code):
    """A BeeScript run (--eval): what it printed."""
    r = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=300, env=dict(os.environ, HOME=T))
    return r.stdout


def port(*a, ok=True):
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a], capture_output=True, text=True, timeout=300, env=dict(os.environ, HOME=T))
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
    return r


def hexf(s):
    return None if s == 'nil' else float.fromhex(s) if s != 'nan' else math.nan


def dump(chans, frames_spec, *pre):
    """Each channel's value at each frame, from --dump-chan after console operators: {frame: [values]}."""
    a, b, st = frames_spec
    out = f'{T}/d.txt'
    if os.path.exists(out):
        os.unlink(out)
    port(*pre, '--dump-chan', f'{out};{a};{b};{st};' + ';'.join(chans))
    res = {}
    for ln in open(out):
        w = ln.split()
        res[float(w[0])] = [hexf(x) for x in w[1:]]
    return res


def ofr(chans, frames_spec, pre, as_op=False):
    """The script's: `pre`, then frame(f); print(prop(c) * 1e6 ...)."""
    a, b, st = frames_spec
    pr = ', '.join(f'prop("{c}")*1000000' for c in chans)
    fl = []
    n = int(math.floor((b - a) / st + 1e-9)) + 1
    go = 'op("anim.frame", "" + f)' if as_op else 'frame(f)'  # (an operator: children then follow)
    code = pre + f'; f = {a}; i = 0; while i < {n} {{ {go}; print("V", f, {pr}); f = f + {st}; i = i + 1 }}'
    res = {}
    for ln in script(code).splitlines():
        w = ln.split()
        if len(w) >= 2 and w[0] == 'V':
            res[float(w[1])] = [float(x) / 1e6 if x != 'nil' else None for x in w[2:]]
    return res


def compare(name, chans, frames_spec, pre_o, *pre_p, as_op=False, tol=TOL, still=()):
    want = ofr(chans, frames_spec, pre_o, as_op)
    got = dump(chans, frames_spec, *pre_p)
    worst, where, n = 0.0, None, 0
    dyn = [set() for _ in chans]
    for f, w in want.items():
        g = got.get(f)
        if g is None or len(g) != len(w):
            check(False, f'{name}: frame {f}: nothing from --dump-chan')
            return
        for k, (x, y) in enumerate(zip(w, g)):
            if x is None or y is None:
                if x != y:
                    worst, where = math.inf, (f, chans[k], x, y)
                continue
            dyn[k].add(round(x, 4))
            e = abs(x - y) / max(1.0, abs(x))
            n += 1
            if e > worst:
                worst, where = e, (f, chans[k], x, y)
    flat = [c for c, d in zip(chans, dyn) if len(d) < 2 and c not in still]
    check(n > 0 and worst <= tol and not flat, f'{name}: {n} values in {len(want)} frames, worst error {worst:.2e} {where if worst > tol else ""}{" - did not move: " + str(flat) if flat else ""}')


# the scenes, as scripts (BeeScript) and as console operators -----------

KEYS = [('Cube:x', 1, 0, ''), ('Cube:x', 25, 4, ''), ('Cube:x', 50, -2, 'linear'), ('Cube:x', 80, 1, 'constant'), ('Cube:x', 100, 3, ''), ('Cube:x', 130, 3, 'bezier'), ('Cube:x', 131, -7, ''),
        ('Cube:y', 1, 1, 'constant'), ('Cube:y', 60, 2, 'constant'), ('Cube:y', 90, 3, 'linear'), ('Cube:y', 120, 8, 'linear'), ('Cube:y', 150, 8.5, ''),
        ('Cube:z', 3, 0, 'bezier'), ('Cube:z', 10, 5, 'bezier'), ('Cube:z', 17, 6, 'bezier'), ('Cube:z', 24, 5.5, 'bezier'), ('Cube:z', 31, -3, 'bezier'), ('Cube:z', 150, 9, 'bezier'),
        ('Cube:rx', 1, 0, ''), ('Cube:rx', 90, 1.5707, ''), ('Cube:ry', 1, -0.7, 'linear'), ('Cube:ry', 75, 0.9, ''), ('Cube:rz', 10, 0.1, ''), ('Cube:rz', 140, -0.8, ''),
        ('Cube:sx', 1, 1, ''), ('Cube:sx', 50, 2, ''), ('Cube:sy', 20, 0.5, 'linear'), ('Cube:sy', 70, 1.5, ''), ('Cube:sz', 5, 3, ''), ('Cube:sz', 95, 0.2, ''),
        ('Light:x', 1, 4, ''), ('Light:x', 60, -4, ''), ('Camera:rz', 1, 0, 'linear'), ('Camera:rz', 30, 0.5, 'linear')]


def okeys(ks):
    return '; '.join(f'key("{p}", {f}, {v}{", " + chr(34) + i + chr(34) if i else ""})' for p, f, v, i in ks)


def pkeys(ks):
    out = []
    for p, f, v, i in ks:
        out += ['--op', f'anim.key {p} {f} {v} {i}'.strip()]
    return out


AX = ['x', 'y', 'z', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz']
CUBE = [f'Cube:{a}' for a in AX]


def s_objects():
    print('-- object channels, every interpolation, a script\'s file and the console\'s --')
    ch = CUBE + ['Light:x', 'Camera:rz']
    fr = (-5, 160, 0.75)
    # the same keys from a script and from the console
    compare('a script and the console', ch, fr, okeys(KEYS), *pkeys(KEYS))
    # each one's file, read back by a script and by the console
    script(okeys(KEYS) + f'; op("file.save", "{T}/o.bee")')
    check(os.path.exists(f'{T}/o.bee'), 'the script saved')
    compare('the script\'s file', ch, fr, f'op("file.open", "{T}/o.bee")', '--op', f'file.open {T}/o.bee')
    port(*pkeys(KEYS), '--op', f'file.save {T}/p.bee')
    compare('the console\'s file', ch, fr, f'op("file.open", "{T}/p.bee")', '--op', f'file.open {T}/p.bee')


SCENE2_O = ('add("sphere"); op("material.new", "Red"); op("material.assign", "Red"); '
            'modifier("Sphere", "array"); modifier("Sphere", "solidify"); '
            'key("material:Red:roughness", 1, 0.1); key("material:Red:roughness", 40, 0.9, "linear"); '
            'key("material:Red:base:0", 1, 0.2); key("material:Red:base:0", 30, 0.8); key("material:Red:base:2", 10, 0.1, "constant"); key("material:Red:base:2", 30, 0.7); '
            'key("material:Red:ior", 1, 1.1); key("material:Red:ior", 30, 2.9); key("material:Red:strength", 1, 0); key("material:Red:strength", 30, 50); '
            'key("modifier:Sphere:0:count", 1, 1, "linear"); key("modifier:Sphere:0:count", 30, 6.4, "linear"); '
            'key("modifier:Sphere:0:x", 1, 0.5); key("modifier:Sphere:0:x", 30, 3); '
            'key("modifier:Sphere:1:thickness", 1, 0.01, "linear"); key("modifier:Sphere:1:thickness", 30, 0.4, "linear")')
SCENE2_P = ['--op', 'add sphere', '--op', 'material.new Red', '--op', 'material.assign Red',
            '--op', 'object.modifier_add array', '--op', 'object.modifier_add solidify'] + sum(
    [['--op', 'anim.key ' + x] for x in [
        'material:Red:roughness 1 0.1', 'material:Red:roughness 40 0.9 linear',
        'material:Red:base:0 1 0.2', 'material:Red:base:0 30 0.8', 'material:Red:base:2 10 0.1 constant', 'material:Red:base:2 30 0.7',
        'material:Red:ior 1 1.1', 'material:Red:ior 30 2.9', 'material:Red:strength 1 0', 'material:Red:strength 30 50',
        'modifier:Sphere:0:count 1 1 linear', 'modifier:Sphere:0:count 30 6.4 linear',
        'modifier:Sphere:0:x 1 0.5', 'modifier:Sphere:0:x 30 3',
        'modifier:Sphere:1:thickness 1 0.01 linear', 'modifier:Sphere:1:thickness 30 0.4 linear']], [])


def s_material_mod():
    print('-- materials and modifiers --')
    ch = ['material:Red:roughness', 'material:Red:base:0', 'material:Red:base:2', 'material:Red:ior', 'material:Red:strength',
          'modifier:Sphere:0:count', 'modifier:Sphere:0:x', 'modifier:Sphere:1:thickness']
    compare('channels', ch, (1, 45, 0.5), SCENE2_O, *SCENE2_P)
    # what the modifier shows at a frame
    want = script(SCENE2_O + '; f = 1; while f < 40 { frame(f); print("V", f, efaces("Sphere")); f = f + 7 }')
    w = [ln.split()[2] for ln in want.splitlines() if ln.startswith('V ')]
    faces = []
    for f in range(1, 40, 7):
        port(*SCENE2_P, '--op', f'anim.frame {f}')
        s = re.findall(r'([0-9,]+) faces', open(f'{T}/u.txt', errors='replace').read())
        faces.append(int(s[-1].replace(',', '')) - 6 if s else -1)
    check([int(x) for x in w] == faces and len(set(faces)) > 1, f'the evaluated faces follow: {faces}, from a script {w}')


LAYERS_O = ('key("Cube:x", 1, 0); key("Cube:x", 11, 3); key("Cube:y", 1, 1, "linear"); key("Cube:y", 11, 2, "linear"); key("Cube:rz", 1, 0); key("Cube:rz", 11, 1); '
            'op("anim.select_keys", "none"); op("anim.action", "Hop"); '
            'add("sphere"); key("Sphere:z", 1, 0, "linear"); key("Sphere:z", 21, 5, "linear"); op("anim.action", "Rise"); '
            'op("anim.layer", "Hop Sphere 5 0.5 replace 2"); op("anim.layer", "Rise - 30 1 add 1.5"); op("anim.layer", "Hop - 60 0.25 add 3"); op("anim.layer", "Hop Cube 100 1 replace 1"); op("anim.layer_set", "4 start 90"); ')
LAYERS_P = sum([['--op', x] for x in [
    'anim.key Cube:x 1 0', 'anim.key Cube:x 11 3', 'anim.key Cube:y 1 1 linear', 'anim.key Cube:y 11 2 linear', 'anim.key Cube:rz 1 0', 'anim.key Cube:rz 11 1',
    'anim.select_keys none', 'anim.action Hop', 'add sphere', 'anim.key Sphere:z 1 0 linear', 'anim.key Sphere:z 21 5 linear', 'anim.action Rise',
    'anim.layer Hop Sphere 5 0.5 replace 2', 'anim.layer Rise - 30 1 add 1.5', 'anim.layer Hop - 60 0.25 add 3', 'anim.layer Hop Cube 100 1 replace 1', 'anim.layer_set 4 start 90']], [])


def s_layers():
    print('-- actions and layers --')
    ch = ['Cube:x', 'Cube:y', 'Cube:rz', 'Sphere:x', 'Sphere:y', 'Sphere:rz', 'Sphere:z']
    compare('layers', ch, (1, 130, 0.5), LAYERS_O, *LAYERS_P)
    script(LAYERS_O + f'; op("file.save", "{T}/ol.bee")')
    compare('layers from the script\'s file', ch, (1, 130, 1.5), f'op("file.open", "{T}/ol.bee")', '--op', f'file.open {T}/ol.bee')
    port(*LAYERS_P, '--op', f'file.save {T}/pl.bee')
    compare('layers from the console\'s file', ch, (1, 130, 1.5), f'op("file.open", "{T}/pl.bee")', '--op', f'file.open {T}/pl.bee')


EDIT_O = ('key("Cube:x", 1, 0); key("Cube:x", 20, 4); key("Cube:x", 40, -1); key("Cube:y", 5, 2); key("Cube:y", 35, -3); key("Cube:z", 1, 0); key("Cube:z", 50, 5); '
          'op("anim.handle", "Cube:x 20 right 10 3"); op("anim.handle", "Cube:x 20 left -5 1"); op("anim.handle", "Cube:y 35 left -15 -6"); '
          'op("anim.select_keys", "Cube:z 50"); op("anim.move_keys", "10 1"); op("anim.select_keys", "Cube:x 40"); op("anim.select_keys", "Cube:y 5 extend"); op("anim.duplicate_keys", "7"); '
          'op("anim.select_keys", "frame 1"); op("anim.scale_keys", "2"); op("anim.select_keys", "Cube:y 35"); op("anim.handle_type", "auto"); op("anim.select_keys", "Cube:y 5"); op("anim.delete_keys"); ')
EDIT_P = sum([['--op', x] for x in [
    'anim.key Cube:x 1 0', 'anim.key Cube:x 20 4', 'anim.key Cube:x 40 -1', 'anim.key Cube:y 5 2', 'anim.key Cube:y 35 -3', 'anim.key Cube:z 1 0', 'anim.key Cube:z 50 5',
    'anim.handle Cube:x 20 right 10 3', 'anim.handle Cube:x 20 left -5 1', 'anim.handle Cube:y 35 left -15 -6',
    'anim.select_keys Cube:z 50', 'anim.move_keys 10 1', 'anim.select_keys Cube:x 40', 'anim.select_keys Cube:y 5 extend', 'anim.duplicate_keys 7',
    'anim.select_keys frame 1', 'anim.scale_keys 2', 'anim.select_keys Cube:y 35', 'anim.handle_type auto', 'anim.select_keys Cube:y 5', 'anim.delete_keys']], [])


def anim_chunk(path):
    return beefile.chunk(path, b'ANIM')


def layout(c):
    """(nkey, ncur, ...) -> the parts: head without CAPK / BYTES, keys."""
    nkey = struct.unpack_from('<I', c, 4)[0] & 0x1fffffff
    head = c[:12] + c[24:]  # (AN_CAPK, AN_BYTES: where memory happened to be)
    return head


def bytes_same(name, a, b):
    if a is None or b is None:
        return check(False, f'{name}: no ANIM chunk ({a is None}, {b is None})')
    la, lb = layout(a), layout(b)
    if la == lb:
        return check(True, f'{name}: {len(a)} bytes identical (but for the block\'s capacity)')
    d = [i for i in range(min(len(la), len(lb))) if la[i] != lb[i]][:12]
    check(False, f'{name}: lengths {len(la)} {len(lb)}, first differences at {d}')


def s_edits():
    print('-- free handles, moved, copied, scaled, deleted keys --')
    ch = ['Cube:x', 'Cube:y', 'Cube:z']
    compare('key edits', ch, (0, 80, 0.5), EDIT_O, *EDIT_P)
    script(EDIT_O + f'; op("file.save", "{T}/oe.bee")')
    port(*EDIT_P, '--op', f'file.save {T}/pe.bee')
    bytes_same('key edits, ANIM', anim_chunk(f'{T}/oe.bee'), anim_chunk(f'{T}/pe.bee'))
    compare('the console\'s file again', ch, (0, 80, 0.5), f'op("file.open", "{T}/pe.bee")', '--op', f'file.open {T}/pe.bee')


DRV_O = ('add("sphere"); op("anim.driver", "Sphere:x a=Cube:x a*2 + 1"); op("anim.driver", "Sphere:y a=Cube:x b=Cube:y sin(a)*b^2 + max(a, b)"); '
         'op("anim.driver", "Sphere:z frame/10 + sqrt(frame) - 2.5cm"); op("anim.driver", "Sphere:rz cos(frame/7)"); op("anim.driver", "Sphere:sx abs(sin(frame*0.1)) + 0.5"); '
         'op("anim.driver", "Sphere:sy floor(frame/4)/2 + round(frame/9) - ceil(frame/30) + min(frame, 3)/atan(1)"); op("anim.driver", "Sphere:sz 45deg + pi/e - 2^0.5 + 1e-2"); '
         'op("anim.driver", "Cube:sz b=Sphere:x b/3"); key("Cube:x", 1, 0); key("Cube:x", 40, 6); key("Cube:y", 1, 1, "linear"); key("Cube:y", 40, 3, "linear"); ')
DRV_P = sum([['--op', x] for x in [
    'add sphere', 'anim.driver Sphere:x a=Cube:x a*2 + 1', 'anim.driver Sphere:y a=Cube:x b=Cube:y sin(a)*b^2 + max(a, b)',
    'anim.driver Sphere:z frame/10 + sqrt(frame) - 2.5cm', 'anim.driver Sphere:rz cos(frame/7)', 'anim.driver Sphere:sx abs(sin(frame*0.1)) + 0.5',
    'anim.driver Sphere:sy floor(frame/4)/2 + round(frame/9) - ceil(frame/30) + min(frame, 3)/atan(1)', 'anim.driver Sphere:sz 45deg + pi/e - 2^0.5 + 1e-2',
    'anim.driver Cube:sz b=Sphere:x b/3', 'anim.key Cube:x 1 0', 'anim.key Cube:x 40 6', 'anim.key Cube:y 1 1 linear', 'anim.key Cube:y 40 3 linear']], [])


def s_drivers():
    print('-- drivers --')
    ch = ['Sphere:x', 'Sphere:y', 'Sphere:z', 'Sphere:rz', 'Sphere:sx', 'Sphere:sy', 'Cube:sz']
    compare('expressions', ch, (1, 60, 0.5), DRV_O, *DRV_P)
    script(DRV_O + f'; op("file.save", "{T}/od.bee")')
    port(*DRV_P, '--op', f'file.save {T}/pd.bee')
    compare('the script\'s drivers', ch, (1, 60, 2.5), f'op("file.open", "{T}/od.bee")', '--op', f'file.open {T}/od.bee')
    compare('the console\'s drivers', ch, (1, 60, 2.5), f'op("file.open", "{T}/pd.bee")', '--op', f'file.open {T}/pd.bee')
    bytes_same('drivers, ANIM', anim_chunk(f'{T}/od.bee'), anim_chunk(f'{T}/pd.bee'))
    # muted, removed
    compare('mute and remove', ['Sphere:x', 'Sphere:rz'], (1, 40, 3.5),
            'add("sphere"); op("anim.driver", "Sphere:x frame*2"); op("anim.driver", "Sphere:rz frame/9"); op("anim.driver", "Sphere:y 1"); key("Sphere:x", 1, 7); key("Sphere:x", 30, 9); op("anim.driver_set", "1 mute 1"); op("anim.driver_set", "3 remove"); op("anim.driver_set", "2 expression sin(frame/5)")',
            '--op', 'add sphere', '--op', 'anim.driver Sphere:x frame*2', '--op', 'anim.driver Sphere:rz frame/9', '--op', 'anim.driver Sphere:y 1', '--op', 'anim.key Sphere:x 1 7', '--op', 'anim.key Sphere:x 30 9', '--op', 'anim.driver_set 1 mute 1', '--op', 'anim.driver_set 3 remove', '--op', 'anim.driver_set 2 expression sin(frame/5)')


SHAPE_O = ('add("sphere"); i = 0; n = verts("Sphere"); while i < n { vmove("Sphere", i, vpos("Sphere", i, 0)*2, vpos("Sphere", i, 1), vpos("Sphere", i, 2)); i = i + 1 }; op("shape.add", "Fat Sphere"); '
           'i = 0; while i < 40 { vmove("Sphere", i, vpos("Sphere", i, 0), vpos("Sphere", i, 1) + 3, vpos("Sphere", i, 2)); i = i + 1 }; op("shape.add", "Up Sphere"); '
           'key("shape:Sphere:Fat", 1, 0); key("shape:Sphere:Fat", 20, 1); key("shape:Sphere:Up", 10, 0, "linear"); key("shape:Sphere:Up", 30, 0.5, "linear"); ')


def overts(frames, pre, name='Sphere', n=482, tail=''):
    res = {f: [] for f in frames}
    for f in frames:
        for first in range(0, n, 300):
            # (print keeps a limited number of lines: a run for each batch)
            code = pre + f'; frame({f}); i = {first}; while i < {min(n, first + 300)} {{ print("V", {f}, evpos("{name}", i, "x")*1000000, evpos("{name}", i, "y")*1000000, evpos("{name}", i, "z")*1000000); i = i + 1 }}'
            for ln in script(code).splitlines():
                w = ln.split()
                if len(w) == 5 and w[0] == 'V':
                    res[float(w[1])].append([float(x) / 1e6 for x in w[2:]])
    return res


def pverts(frames, *pre, name='Sphere'):
    res = {}
    for f in frames:
        port(*pre, '--op', f'anim.frame {f}', '--dump-verts', f'{T}/v.txt;{name}')
        res[f] = [[float.fromhex(x) for x in ln.split()] for ln in open(f'{T}/v.txt')]
    return res


def cmp_verts(name, want, got):
    worst, n, moved = 0.0, 0, False
    base = None
    for f in want:
        a, b = want[f], got[f]
        if len(a) != len(b) or not a:
            return check(False, f'{name}: frame {f}: {len(a)} and {len(b)} vertices')
        if base is None:
            base = a
        elif a != base:
            moved = True
        for p, q in zip(a, b):
            n += 1
            worst = max(worst, max(abs(x - y) for x, y in zip(p, q)))
    check(n > 0 and worst < 2e-5 and moved, f'{name}: {n} vertices, worst {worst:.2e}, they move: {moved}')


def s_shapes():
    print('-- shape keys --')
    fr = [1.0, 5.0, 14.5, 20.0, 30.0, 40.0]
    script(SHAPE_O + f'op("file.save", "{T}/os.bee")')
    want = overts(fr, f'op("file.open", "{T}/os.bee")')
    got = pverts(fr, '--op', f'file.open {T}/os.bee')
    cmp_verts('a script\'s keys evaluated, by a script and the console', want, got)
    compare('their values', ['shape:Sphere:Fat', 'shape:Sphere:Up'], (1, 40, 1.5), f'op("file.open", "{T}/os.bee")', '--op', f'file.open {T}/os.bee')
    port('--op', f'file.open {T}/os.bee', '--op', f'file.save {T}/ps.bee')
    a, b = beefile.chunk(f'{T}/os.bee', b'MSHK'), beefile.chunk(f'{T}/ps.bee', b'MSHK')
    check(a is not None and b is not None and a[4:] == b[4:], f'MSHK opened and saved again: {len(a or b"")} bytes identical (but for the mesh\'s place in its own file)')
    bytes_same('ANIM opened and saved again', anim_chunk(f'{T}/os.bee'), anim_chunk(f'{T}/ps.bee'))
    cmp_verts('the file saved again, evaluated by a script', want, overts(fr, f'op("file.open", "{T}/ps.bee")'))
    # a modifier on top: shape keys first
    script(SHAPE_O + f'modifier("Sphere", "array"); op("file.save", "{T}/osm.bee")')
    fr2 = [1.0, 20.0, 30.0]
    cmp_verts('under a modifier', overts(fr2, f'op("file.open", "{T}/osm.bee")', n=964), pverts(fr2, '--op', f'file.open {T}/osm.bee'))
    # made in the window: an edit, shape.add, keys
    made = ['--op', 'add sphere', '--op', 'shape.add Rise', '--move', '615,360', '--key', 'tab', '--key', 'g', '--key', 'y', '--type', '2', '--key', 'enter', '--key', 'tab',
            '--op', 'shape.add Rise', '--op', 'anim.key shape:Sphere:Rise 1 0', '--op', 'anim.key shape:Sphere:Rise 11 1']
    port(*made, '--op', f'file.save {T}/pm.bee', '--expect-anim', 'shapes:Sphere=2')
    m = beefile.chunk(f'{T}/pm.bee', b'MSHK')
    check(m is not None and len(m) > 1056, f'a key made there is in the file ({len(m or b"")} bytes)')
    fr3 = [1.0, 6.0, 11.0]
    cmp_verts('made there, evaluated by a script and the console', overts(fr3, f'op("file.open", "{T}/pm.bee")'), pverts(fr3, '--op', f'file.open {T}/pm.bee'))
    o = script(f'op("file.open", "{T}/pm.bee"); print("S", shapes("Sphere"), vpos("Sphere", 0, 1))')
    check('S 2 1' in o, f'a script reads it, the Basis back in the mesh: {o.strip()[-30:]}')
    # shape.edit, remove, clear, undo
    r = port(*made, '--op', 'shape.remove Rise', '--expect-anim', 'shapes:Sphere=1', '--op', 'edit.undo', '--expect-anim', 'shapes:Sphere=2', '--op', 'shape.clear', '--expect-anim', 'shapes:Sphere=0', '--op', 'edit.undo', '--expect-anim', 'shapes:Sphere=2', '--op', 'shape.set Rise 0.5', '--expect-anim', 'shape:Sphere:Rise=0.5', '--op', 'edit.undo', '--expect-anim', 'shape:Sphere:Rise=0', ok=False)
    check(r.returncode == 0, f'shape.remove, shape.clear, shape.set: one undo step each {r.stderr[-200:]}')


PAR_O = ('add("sphere"); set("Sphere", "x", 3); set("Sphere", "y", 1); add("cylinder"); set("Cylinder", "y", 2); set("Cylinder", "z", 2); '
         'key("Sphere:x", 1, 3); key("Sphere:x", 20, 7); key("Cylinder:y", 1, 2); key("Cylinder:y", 30, -2); key("Cube:rz", 1, 0); key("Cube:rz", 40, 1.2); key("Cube:y", 1, 1); key("Cube:y", 40, 4); '
         'op("object.parent_set", "Sphere Cube"); op("object.parent_set", "Cylinder Sphere"); frame(1); ')
PAR_P = sum([['--op', x] for x in [
    'add sphere', 'move 3 1 0', 'add cylinder', 'move 0 2 2', 'anim.key Sphere:x 1 3', 'anim.key Sphere:x 20 7', 'anim.key Cylinder:y 1 2', 'anim.key Cylinder:y 30 -2',
    'anim.key Cube:rz 1 0', 'anim.key Cube:rz 40 1.2', 'anim.key Cube:y 1 1', 'anim.key Cube:y 40 4',
    'object.parent_set Sphere Cube', 'object.parent_set Cylinder Sphere', 'anim.frame 1']], [])


def s_parents():
    print('-- children: their channels are world values, they take their parents\' change --')
    a = ofr(['Sphere:x', 'Cube:y'], (1, 3, 1), PAR_O)
    check(len(a) == 3, f'the scene runs as a script ({len(a)} frames)')
    ch = ['Sphere:x', 'Sphere:y', 'Sphere:z', 'Sphere:rz', 'Cylinder:x', 'Cylinder:y', 'Cylinder:z', 'Cube:rz']
    # stepped: the result hangs on the step (par_sync takes each change)
    compare('stepping frame by frame', ch, (1, 45, 1), PAR_O, *PAR_P, as_op=True, tol=5e-6, still=('Sphere:z', 'Cylinder:z'))


def s_uids():
    print('-- object references across files --')
    # a uid not its index + 1: an object deleted before
    code = 'add("sphere"); add("cylinder"); delete("Sphere"); key("Cylinder:x", 1, 0); key("Cylinder:x", 21, 8); op("anim.driver", "Cube:y a=Cylinder:x a/2"); op("anim.action", "A"); '
    script(code + f'op("file.save", "{T}/ou.bee")')
    o = script(f'op("file.open", "{T}/ou.bee"); print("OBJ", count(), name(3))')
    compare('a deleted object before it', ['Cylinder:x', 'Cube:y'], (1, 25, 2), f'op("file.open", "{T}/ou.bee")', '--op', f'file.open {T}/ou.bee')
    port('--op', f'file.open {T}/ou.bee', '--op', f'file.save {T}/pu.bee')
    compare('opened and saved again, renumbered', ['Cylinder:x', 'Cube:y'], (1, 25, 2), f'op("file.open", "{T}/pu.bee")', '--op', f'file.open {T}/pu.bee')
    # uids persist (OB_UID): opened and saved again, they are kept, gap and all
    script(f'op("file.open", "{T}/ou.bee"); op("file.save", "{T}/ou2.bee")')
    c, c2 = anim_chunk(f'{T}/pu.bee'), anim_chunk(f'{T}/ou2.bee')
    uids, uids2 = beefile.chunk(f'{T}/pu.bee', b'UIDS'), beefile.chunk(f'{T}/ou2.bee', b'UIDS')
    a = struct.unpack_from('<I', c, 8 + 60 + 4)[0] if c else None
    check(c is not None and c == c2 and uids == uids2, f'its curves name the uids it wrote ({a}), from the console and from a script alike')
    # rigid bodies, constraints in the chunk: kept, references right
    code = ('add("sphere"); select("Sphere"); op("rigid.add", "active box"); add("cylinder"); op("constraint.add", "Cylinder copy_location Sphere"); op("rigid.joint", "hinge Sphere world pivot 0 1 0 axis 0 1 0"); key("Cube:x", 1, 0); key("Cube:x", 9, 1); ')
    script(code + f'op("file.save", "{T}/or.bee")')
    port('--op', f'file.open {T}/or.bee', '--op', f'file.save {T}/pr.bee')
    bytes_same('bodies, joints, constraints kept', anim_chunk(f'{T}/or.bee'), anim_chunk(f'{T}/pr.bee'))


def s_undo():
    print('-- undo --')
    r = port('--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 4', '--expect-anim', 'keys=2', '--expect-anim', 'undo=2',
             '--op', 'anim.frame 25', '--expect-anim', 'Cube:x=4', '--expect-anim', 'undo=2',
             '--op', 'anim.frame 13', '--op', 'anim.next_frame', '--expect-anim', 'undo=2', '--expect-anim', 'frame=14',
             '--op', 'edit.undo', '--expect-anim', 'keys=1', '--op', 'edit.undo', '--expect-anim', 'curves=0', '--op', 'edit.redo', '--expect-anim', 'keys=1', '--op', 'edit.redo', '--expect-anim', 'keys=2',
             '--op', 'anim.select_keys all', '--expect-anim', 'undo=2', '--expect-anim', 'selected=2', '--op', 'anim.delete_keys', '--expect-anim', 'keys=0', '--op', 'edit.undo', '--expect-anim', 'keys=2',
             '--op', 'anim.select_keys all', '--op', 'anim.move_keys 5', '--expect-anim', 'keys=2', '--op', 'edit.undo', '--op', 'anim.frame 6', '--expect-anim', 'undo=2', ok=False)
    check(r.returncode == 0, f'keys in steps, frames not: {r.stderr[-300:]}')
    r = port('--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 4', '--op', 'anim.driver Cube:y a=Cube:x a*2', '--expect-anim', 'undo=3', '--op', 'edit.undo', '--expect-anim', 'drivers=0', '--op', 'edit.redo', '--expect-anim', 'drivers=1',
             '--op', 'anim.frame 13', '--op', 'anim.frame 20', '--expect-anim', 'undo=3', ok=False)
    check(r.returncode == 0, f'drivers in steps, a driver writing is none: {r.stderr[-300:]}')
    # material and modifier keys evaluated are not steps
    r = port(*SCENE2_P, '--op', 'anim.frame 3', '--op', 'anim.frame 30', '--expect-anim', 'undo=20', ok=False)
    check(r.returncode == 0, f'material, modifier values evaluated: no step {r.stderr[-200:]}')
    # the step before a frame change undoes to the frame's values
    r = port('--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 4', '--op', 'anim.frame 25', '--op', 'move 0 0 1', '--expect-anim', 'Cube:z=1', '--op', 'edit.undo', '--expect-anim', 'Cube:z=0', '--expect-anim', 'Cube:x=4', ok=False)
    check(r.returncode == 0, f'a move at a frame undoes to that frame: {r.stderr[-200:]}')


def s_mat_undo():
    print('-- a material edited with a driver on its object: its own step --')
    E = lambda *w: [x for s in w for x in ('--expect-anim', s)]
    r = port('--op', 'material.new M', '--op', 'material.set M roughness 0.2', '--op', 'anim.driver material:M:roughness a=material:M:metallic 0.5+a*0.25', *E('undo=3', 'material:M:roughness=0.5'),
             '--op', 'material.set M metallic 1', *E('undo=4', 'material:M:metallic=1', 'material:M:roughness=0.75'), '--op', 'edit.undo', *E('undo=3', 'material:M:metallic=0', 'material:M:roughness=0.5'), ok=False)
    check(r.returncode == 0, f'undone {r.stderr[-260:].strip()}')


def s_undo_shapes():
    print('-- undo past shape keys --')
    E = lambda *w: [x for s in w for x in ('--expect-anim', s)]
    r = port('--op', 'add sphere', '--op', 'shape.add Smile', '--move', '615,360', '--key', 'tab', '--key', 'g', '--key', 'y', '--type', '2', '--key', 'enter', '--key', 'tab', '--op', 'shape.add Smile', '--op', 'shape.set Smile 0.3 Sphere', *E('shape:Sphere:Smile=0.3'), '--dump-verts', f'{T}/sk0.txt;Sphere', '--op', 'anim.key shape:Sphere:Smile 1 0', '--op', 'anim.key shape:Sphere:Smile 25 1',
             '--op', 'anim.frame 25', *E('shape:Sphere:Smile=1'), '--dump-verts', f'{T}/sk2.txt;Sphere', '--op', 'edit.undo', '--op', 'edit.undo', *E('curves=0', 'shape:Sphere:Smile=0.3'), '--dump-verts', f'{T}/sk1.txt;Sphere',
             '--op', 'edit.redo', '--op', 'edit.redo', *E('curves=1', 'shape:Sphere:Smile=1'), ok=False)
    check(r.returncode == 0, f'a shape key\'s value from before its keys comes back: {r.stderr[-260:].strip()}')
    check(open(f'{T}/sk0.txt').read() == open(f'{T}/sk1.txt').read() and open(f'{T}/sk0.txt').read() != open(f'{T}/sk2.txt').read(), 'and the vertices, to the bit')


def s_bad_frames():
    print('-- a key\'s frame is a number --')
    # typed: a scale that overflows leaves the key where it was
    r = port('--op', 'anim.key Cube:x 5 1', '--op', 'anim.select_keys all', '--op', 'anim.scale_keys 1e38', '--op', 'anim.scale_keys 1e38', '--op', 'anim.select_keys all', '--op', 'anim.scale_keys 0', '--op', 'anim.frame 2', '--expect-anim', 'curves=1', '--expect-anim', 'keys=1', '--expect-anim', 'value:Cube:x:1=1', ok=False)
    check(r.returncode == 0, f'scaled to nothing and back: no crash, the key there {r.returncode} {r.stderr[-200:].strip()}')
    r = port('--op', 'anim.key Cube:x 5 3e38', '--op', 'anim.select_keys all', '--op', 'anim.move_keys 0 3e38', '--op', 'anim.frame 5', '--expect-anim', 'keys=1', '--expect-anim', 'Cube:x=300000000549775580000000000000000000000', ok=False)
    check(r.returncode == 0, f'a value moved past a float: it stays {r.returncode} {r.stderr[-200:].strip()}')
    # a file: all of the chunk or none
    port('--op', 'anim.key Cube:x 5 1', '--op', 'anim.key Cube:y 1 2', '--op', 'anim.key Cube:y 9 3', '--op', f'file.save {T}/nf.bee')
    d = open(f'{T}/nf.bee', 'rb').read()
    o = 8
    while True:
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if tag == b'ANIM':
            break
        o += 8 + size
    last = o + 8 + size - 32  # (the last key's, a curve's only one when sorted so)
    for name, off, v in (('NaN, a one-key curve', o + 8 + size - 96, 0x7fc00000), ('inf, a one-key curve', o + 8 + size - 96, 0x7f800000), ('-inf in a longer one', last, 0xff800000), ('NaN in a longer one', last, 0xffc00000)):
        b = bytearray(d)
        struct.pack_into('<I', b, off, v)
        open(f'{T}/nf2.bee', 'wb').write(b)
        r = port('--op', f'file.open {T}/nf2.bee', '--expect-anim', 'keys=0', '--op', 'anim.frame 3', '--op', 'area.type_graph_editor', '--op', 'area.type_dope_sheet', ok=False)
        check(r.returncode == 0, f'{name}: refused {r.returncode} {r.stderr[-200:].strip()}')


def s_no_step():
    print('-- what changes nothing is no step --')
    E = lambda *w: [x for s in w for x in ('--expect-anim', s)]
    k = ['--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 25 4', *E('undo=2')]
    r = port(*k, '--op', 'anim.unkey Cube:x 7', *E('undo=2', 'keys=2'), '--op', 'anim.unkey Cube:x 25', *E('undo=3', 'keys=1'), ok=False)
    check(r.returncode == 0, f'anim.unkey where there is no key {r.stderr[-200:].strip()}')
    r = port(*k, '--op', 'constraint.remove 9', *E('undo=2'), '--op', 'constraint.remove Cube', *E('undo=2'), '--op', 'constraint.remove nothing', *E('undo=2'), ok=False)
    check(r.returncode == 0, f'constraint.remove of no constraint {r.stderr[-200:].strip()}')
    # these are recorded
    r = port(*k, '--op', 'anim.handle_type auto', *E('undo=3'), ok=False)
    check(r.returncode == 0, f'anim.handle_type with nothing selected: a step {r.stderr[-200:].strip()}')
    r = port(*k, '--op', 'anim.frame 7', '--select', 'Cube', '--op', 'anim.delete_key', *E('undo=3', 'keys=2'), ok=False)
    check(r.returncode == 0, f'anim.delete_key where there is no key: a step {r.stderr[-200:].strip()}')
    # the timeline's fields with a speed no field shows
    r = port('--size', '1400x900', '--op', 'anim.range 1 10 1e30', '--op', 'area.type_timeline', '--dbl-label', 'Start', '--type', '5', '--key', 'enter', '--expect-anim', 'frame=1', ok=False)
    check(r.returncode == 0, f'a huge fps, Start edited {r.returncode} {r.stderr[:160].strip()}')


def flip(b, rng, lo, hi):
    n = 1 + rng.randrange(12)
    for _ in range(n):
        i = rng.randrange(lo, hi)
        m = rng.randrange(4)
        if m == 0:
            b[i] ^= 1 << rng.randrange(8)
        elif m == 1:
            b[i] = rng.choice([0, 0xff, 0x7f, 0x80])
        elif m == 2:
            j = i & ~3
            if j + 4 <= hi:
                b[j:j + 4] = struct.pack('<I', rng.choice([0xffffffff, 0x7fffffff, 0x80000000, 1, 1024, 1025, 0x1000001, 4096]))
        else:
            j = i & ~3
            if j + 4 <= hi:
                b[j:j + 4] = struct.pack('<f', rng.choice([math.nan, math.inf, -math.inf, 1e30, -1e30, 0.0]))


def patch_key(src, dst, k, off, value):
    """A port-saved file with key k's float at `off` changed (key 0 of its chunk)."""
    d = bytearray(open(src, 'rb').read())
    o = 8
    while o + 8 <= len(d):
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if tag == b'ANIM':
            keys = o + 8 + size - struct.unpack_from('<I', d, o + 8 + 4)[0] % (1 << 24) * 32
            struct.pack_into('<f', d, keys + k * 32 + off, value)
        o += 8 + size
    open(dst, 'wb').write(d)


def s_damage():
    print(f'-- damaged chunks ({RUNS} files) --')
    rng = random.Random(SEED)
    # what a damaged number must not do: reach the scene
    port('--op', 'anim.key Cube:x 1 2', '--op', 'anim.key Cube:x 9 3', '--op', 'anim.frame 1', '--op', f'file.save {T}/n.bee')
    for what, v in (('NaN', math.nan), ('infinity', math.inf)):
        patch_key(f'{T}/n.bee', f'{T}/n2.bee', 0, 4, v)
        r = port('--op', f'file.open {T}/n2.bee', '--op', 'anim.frame 1', '--expect-anim', 'Cube:x=2', '--op', 'area.type_graph_editor', ok=False)
        check(r.returncode == 0, f'a key of {what}: the object keeps its place {r.stderr[-120:]}')
    patch_key(f'{T}/n.bee', f'{T}/n2.bee', 0, 0, math.nan)
    r = port('--op', 'area.type_dope_sheet', '--op', f'file.open {T}/n2.bee', '--op', 'anim.frame 5', '--op', 'area.type_graph_editor', '--op', 'anim.frame 5', ok=False)
    check(r.returncode in (0, 2), f'a frame of NaN: draws, evaluates (exit {r.returncode}) {r.stderr[-120:]}')
    sources = []
    port(*made_all(), '--op', f'file.save {T}/pall.bee')
    for f in (f'{T}/pall.bee',):
        d = open(f, 'rb').read()
        sources.append(d)
    crashes = 0
    rep = 0
    for k in range(RUNS):
        d = bytearray(rng.choice(sources))
        o = 8
        spans = []
        while o + 8 <= len(d):
            tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
            if tag in (b'ANIM', b'MSHK'):
                spans.append((tag, o, size))
            o += 8 + size
        tag, o, size = rng.choice(spans)
        if rng.random() < 0.25 and tag == b'ANIM':
            # the counts, the first keys, where it hurts
            flip(d, rng, o + 8, o + 8 + 64)
            flip(d, rng, o + 8 + 71300 - 8, min(o + 8 + size, o + 8 + 71300 + 256))
        elif rng.random() < 0.5:
            flip(d, rng, o + 8, o + 8 + min(size, 1200))
        else:
            flip(d, rng, o + 8, o + 8 + size)
        if rng.random() < 0.15:
            # cut
            cut = rng.randrange(size)
            struct.pack_into('<I', d, o + 4, cut)
            d = d[:o + 8 + cut] + d[o + 8 + size:]
        p = f'{T}/dmg.bee'
        open(p, 'wb').write(d)
        out = f'{T}/d.ppm'
        r = subprocess.run([BIN, '--shot', out, '--size', '900x620', '--op', 'area.type_dope_sheet', '--op', f'file.open {p}', '--op', 'anim.frame 13', '--op', 'anim.frame 7.5', '--op', 'area.type_graph_editor', '--op', 'anim.select_keys all', '--op', 'anim.frame 30', '--op', 'anim.motion_paths 1 8', '--op', 'anim.onion 2 2 1',
                            '--op', f'file.save {T}/dmg2.bee', '--op', f'file.open {T}/dmg2.bee', '--op', 'edit.undo'], capture_output=True, text=True, timeout=120)
        if r.returncode not in (0, 2):
            crashes += 1
            print(f'  run {k} ({tag}): exit {r.returncode}: {r.stderr[-600:]}')
            open(f'/tmp/dmg-crash-{k}.bee', 'wb').write(d)
            if crashes > 3:
                break
    check(crashes == 0, f'{RUNS} damaged ANIM / MSHK: no crash')


def made_all():
    return (['--op', 'add sphere', '--op', 'shape.add Rise', '--move', '615,360', '--key', 'tab', '--key', 'g', '--key', 'y', '--type', '2', '--key', 'enter', '--key', 'tab', '--op', 'shape.add Rise',
             '--op', 'anim.key shape:Sphere:Rise 1 0', '--op', 'anim.key shape:Sphere:Rise 11 1', '--op', 'anim.key Sphere:x 2 3', '--op', 'anim.key Sphere:x 40 1 linear', '--op', 'anim.key Sphere:y 1 1 constant', '--op', 'anim.key Sphere:y 30 2',
             '--op', 'anim.key Cube:x 1 0', '--op', 'anim.key Cube:x 5 1', '--op', 'anim.key Cube:x 9 0', '--op', 'anim.handle Cube:x 5 right 3 1', '--op', 'anim.driver Cube:y a=Cube:x sin(a) + frame/10', '--op', 'anim.action Act', '--op', 'anim.layer Act Cube 1 0.5 add 3'])


def png(path):
    from PIL import Image
    return Image.open(path).convert('RGB')


def mean_diff(a, b):
    import numpy as np
    return float(np.abs(np.asarray(a, dtype=float) - np.asarray(b, dtype=float)).mean())


def s_render():
    print('-- render.animation and Rendered playback really move --')
    w = f'{T}/rn'
    os.makedirs(w, exist_ok=True)
    ops = ['render.settings 96 54 24', 'material.new Red', 'material.assign Red', 'anim.key material:Red:base:1 1 0.9 linear', 'anim.key material:Red:base:1 3 0.1 linear',
           'anim.key Cube:x 1 -2 linear', 'anim.key Cube:x 3 2 linear', 'anim.key Cube:rz 1 0 linear', 'anim.key Cube:rz 3 1.2 linear',
           'anim.key Camera:rz 1 0 linear', 'anim.key Camera:rz 3 0.3 linear', 'anim.key Light:x 1 4 linear', 'anim.key Light:x 3 -4 linear', f'file.save {w}/p.bee', f'render.animation {w}/pf.png 1 3']
    port(*sum([['--op', x] for x in ops], []))
    got = sorted(os.listdir(f'{w}/pf')) if os.path.isdir(f'{w}/pf') else []
    check(got == ['0001.png', '0002.png', '0003.png'], f'it rendered its frames: {got}')
    if got:
        p = [png(f'{w}/pf/{n}') for n in got]
        moved = mean_diff(p[0], p[2])
        check(moved > 5, f'frame 1 against frame 3: {moved:.1f} of 255: it moved')
    # shape keys and modifiers reach the tracer
    script(SHAPE_O + f'delete("Cube"); op("file.save", "{w}/sh.bee")')
    port('--op', f'file.open {w}/sh.bee', '--op', 'render.settings 96 54 24', '--op', f'render.animation {w}/ps.png 1 1', '--op', f'render.animation {w}/ps2.png 30 30')
    if os.path.exists(f'{w}/ps/0001.png') and os.path.exists(f'{w}/ps2/0030.png'):
        a, b = png(f'{w}/ps/0001.png'), png(f'{w}/ps2/0030.png')
        check(mean_diff(a, b) > 1, f'a shape key rendered: frame 1 to 30 {mean_diff(a, b):.2f}')
    else:
        check(False, 'a shape key rendered: no frames')
    # Rendered, playing: each new frame gets its samples on the CPU
    base = ['--size', '640x420', '--op', 'render.device cpu', '--op', 'view.rendered_samples 64', '--op', 'view.rendered_denoise 0', '--op', 'anim.key Cube:x 1 -3 linear', '--op', 'anim.key Cube:x 25 3 linear', '--op', 'view.shading_rendered']
    env_port = lambda out, *a: subprocess.run([BIN, '--shot', out, *base, *a], capture_output=True, text=True, timeout=120, env=dict(os.environ, HOME=T))
    r0 = env_port(f'{w}/l0.ppm', '--op', 'view.rendered_playback 0', '--op', 'view.rendered_motion 0', '--op', 'anim.frame 1', '--op', 'anim.play', '--wait', '100', '--bench', '1', '--expect-anim', 'live_samples=0')
    r1 = env_port(f'{w}/l1.ppm', '--op', 'view.rendered_playback 3', '--op', 'anim.frame 1', '--op', 'anim.play', '--wait', '100', '--bench', '1', '--expect-anim', 'live_samples=3', '--expect-anim', 'frame=3')
    r2 = env_port(f'{w}/l2.ppm', '--op', 'view.rendered_playback 3', '--op', 'anim.frame 1', '--op', 'anim.play', '--wait', '800', '--bench', '1', '--expect-anim', 'live_samples=3', '--expect-anim', 'frame=20')
    check(r0.returncode == 0 and r1.returncode == 0 and r2.returncode == 0, f'playing, each new frame has the playback samples, 0: none {r0.stderr[-120:]} {r1.stderr[-120:]} {r2.stderr[-120:]}')
    r3 = env_port(f'{w}/l3.ppm', '--op', 'view.rendered_playback 3', '--op', 'anim.frame 1', '--op', 'anim.play', '--wait', '100', '--bench', '1', '--op', 'anim.play', '--bench', '1', '--live-wait', '--expect-anim', 'live_samples=64')
    check(r3.returncode == 0, f'stopped, the frame gets its full samples {r3.stderr[-120:]}')
    crop = (160, 150, 500, 350)
    c1, c2 = png(f'{w}/l1.ppm').crop(crop), png(f'{w}/l2.ppm').crop(crop)
    check(mean_diff(c1, c2) > 2, f'the path-traced frames differ: the cube moved ({mean_diff(c1, c2):.2f})')


def s_window():
    print('-- in a window: an idle window draws nothing --')
    from wl_fake import Fake
    ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
    ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, ':': 39, '-': 12})
    ROW.update({str(i): i + 1 for i in range(1, 10)})

    def line(f, s):
        f.key(28)
        for c in s:
            if c == '_':
                f.key(12, 1)
            elif c == ':':
                f.key(39, 1)
            elif c.isupper():
                f.key(ROW[c.lower()], 1)
            else:
                f.key(ROW[c])
        f.key(28)
        f.key(1)
        f.pump(0.3)

    def still(f):
        last = -1
        for _ in range(40):
            f.pump(0.1)
            if f.frames == last:
                break
            last = f.frames

    f = Fake(BIN)
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)
    f.enter(600, 300)
    f.motion(605, 305)
    f.pump(0.3)
    line(f, 'anim.key Cube:x 1 0')
    line(f, 'anim.key Cube:x 25 4')
    still(f)
    n = f.frames
    f.pump(1.2)
    check(f.frames == n, f'keys, not playing: {f.frames - n} frames in 1.2 s')
    line(f, 'anim.play')
    n = f.frames
    f.pump(1.0)
    played = f.frames - n
    check(12 <= played <= 40, f'playing: {played} frames in a second (24 fps)')
    line(f, 'anim.play')
    still(f)
    n = f.frames
    f.pump(1.2)
    check(f.frames == n, f'paused: {f.frames - n} frames in 1.2 s')
    f.close()


def main():
    print(f'seed {SEED}')
    only = os.environ.get('ANIM_ONLY', '')
    for s in (s_objects, s_material_mod, s_layers, s_edits, s_drivers, s_shapes, s_parents, s_uids, s_undo, s_mat_undo, s_undo_shapes, s_bad_frames, s_no_step, s_render, s_window, s_damage):
        if not only or s.__name__ in only.split(','):
            s()
    print('fails', len(FAILS))
    sys.exit(1 if FAILS else 0)


main()
