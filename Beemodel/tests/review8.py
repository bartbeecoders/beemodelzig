#!/usr/bin/env python3
"""Two defects the phase 8 review found:

  - an undone sculpt stroke, out of sculpt mode, after the view had drawn the
    stroke: the view shows the mesh as it is again (the image cache's key now
    follows the mesh's shape stamp, not only its slot and serial)
  - applying an Armature modifier keeps the mesh's UVs, seams and shape keys,
    (weights and colours already came along), by the op and by BeeScript's
    modapply

    python3 tests/review8.py BIN
"""
import os, struct, subprocess, sys, tempfile
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'zig-out-debug/bin/beemodel'))
T = tempfile.mkdtemp(prefix='beerv8-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
fails = 0


def check(ok, what):
    global fails
    print(('  ok   ' if ok else '  FAIL ') + what)
    if not ok:
        fails += 1


def script(code, what):
    p = os.path.join(T, 's.bees')
    open(p, 'w').write(code)
    r = subprocess.run([BIN, '--run', p], capture_output=True, text=True, timeout=600, env=ENV)
    check(r.returncode == 0, f'{what}: the script ran (exit {r.returncode})')
    if r.returncode != 0:
        print('  ', r.stdout[-300:], r.stderr[-300:])


def port(name, *args):
    shot = os.path.join(T, name + '.ppm')
    a = [BIN, '--shot', shot]
    for s in args:
        a += list(s) if isinstance(s, tuple) else ['--op', s]
    r = subprocess.run(a, capture_output=True, text=True, timeout=600, env=ENV)
    if r.returncode != 0:
        print('  rc', r.returncode, r.stderr[-400:])
    return shot


def ppm(p):
    d = open(p, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def crop(p, box):
    w, h, px = ppm(p)
    x0, y0, x1, y1 = box
    return b''.join(px[(y * w + x0) * 3:(y * w + x1) * 3] for y in range(y0, y1))


def uvrec(p, name):
    ob = {o['name']: o['mesh'] for o in beefile.objects(p)}
    d = beefile.chunk(p, b'MUVS') or b''
    o, out = 0, {}
    while o + 12 <= len(d):
        ix, fl, nl = struct.unpack_from('<III', d, o)
        out[ix] = (fl, nl)
        o += 12 + (nl * 8 if fl & 1 else 0) + (((nl + 3) & ~3) if fl & 2 else 0)
    return out.get(ob[name])


print('-- an undone stroke out of sculpt mode: the view follows --')
ball = os.path.join(T, 'ball.bee')
script(f'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\nop("file.save", "{ball}")\n', 'the ball')
pre = (f'file.open {ball}', ('--select', 'S'), 'view.frame_selected')
stroke = 'sculpt S "draw" -0.8 2 1 0.8 2.2 0.9 0.8 1'
moves = (('--move', '300,300'), ('--move', '310,300'), ('--move', '320,300'))
box = (440, 160, 840, 460)
for sh in ('view.shading_solid', 'view.shading_material'):
    clean = crop(port('clean', *pre, sh, *moves), box)
    drawn = crop(port('drawn', *pre, sh, stroke, 'mode.object', *moves), box)
    undone = crop(port('undone', *pre, sh, stroke, 'mode.object', *moves, 'edit.undo', *moves), box)
    redone = crop(port('redone', *pre, sh, stroke, 'mode.object', *moves, 'edit.undo', *moves, 'edit.redo', *moves), box)
    tag = sh.split('_')[-1]
    check(drawn != clean, f'{tag}: the stroke shows')
    check(undone == clean, f'{tag}: undone, the view is the clean ball ({sum(a != b for a, b in zip(undone, clean))} bytes differ)')
    check(redone == drawn, f'{tag}: redone, the stroke again ({sum(a != b for a, b in zip(redone, drawn))} bytes differ)')

print('-- Armature applied: UVs, seams and shape keys stay --')
k0, k1, k2 = (os.path.join(T, f'k{i}.bee') for i in range(3))
script(f'''delete("Cube")
add("sphere", "S", 0, 2, 0)
scale("S", 3.5, 3.5, 3.5)
a = armature("Rig")
op("arm.bone", "Up Bone 0 2 0 0 5 0")
op("arm.parent", "S Rig")
select("S")
op("uv.smart_project")
op("mode.edit")
op("uv.seam_mark")
op("mode.object")
op("shape.add", "Up S")
op("file.save", "{k0}")
modapply("S", 0)
op("file.save", "{k1}")
''', 'the rig')
port('apply', f'file.open {k0}', ('--select', 'S'), 'object.modifier_apply 0', f'file.save {k2}')
c = [{t.decode(): b for t, b in beefile.chunks(k)} if os.path.exists(k) else {} for k in (k0, k1, k2)]
check(uvrec(k0, 'S') is not None and uvrec(k0, 'S')[0] == 3 and len(c[0].get('MSHK', b'')) > 0 and len(c[0].get('MWGT', b'')) > 0,
      f'before: UVs and seams {uvrec(k0, "S")}, shape keys, weights')
for k, (path, how) in enumerate(((k1, 'modapply'), (k2, 'the op')), 1):
    check(uvrec(path, 'S') == uvrec(k0, 'S'), f'{how}: UVs and seams stay: {uvrec(path, "S")}')
    check(len(c[k].get('MSHK', b'')) == len(c[0].get('MSHK', b'')), f'{how}: shape keys stay: {len(c[k].get("MSHK", b""))} bytes')
    check(len(c[k].get('MWGT', b'')) == len(c[0].get('MWGT', b'')), f'{how}: the weights stay: {len(c[k].get("MWGT", b""))} bytes')
    check(c[k].get('MODS', b'') != c[0].get('MODS', b''), f'{how}: the modifier left the stack')
check(c[1].get('MODS', b'') == c[2].get('MODS', b''), 'modapply and the op leave the same stack')

print('review8 fails', fails)
sys.exit(1 if fails else 0)
