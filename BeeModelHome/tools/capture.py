#!/usr/bin/env python3
"""Screenshots for the website, taken from BeeModel itself.

Each shot is one headless run of the Zig build (`beemodel --shot`: no window,
no compositor, no GPU): a BeeScript scene from scenes/ builds the picture, a
few console lines and clicks arrange the UI, and the frame lands in
media/shots/<name>.png.

  python3 BeeModelHome/tools/capture.py [path/to/beemodel] [shot ...]
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.abspath(os.path.join(HERE, '..'))
ROOT = os.path.abspath(os.path.join(HOME, '..'))
SCENES = os.path.join(HOME, 'scenes')
OUT = os.path.join(HOME, 'media', 'shots')
args = sys.argv[1:]
BIN = os.path.abspath(args.pop(0)) if args and '/' in args[0] \
    else os.path.join(ROOT, 'Beemodel', 'zig-out', 'bin', 'beemodel')
ONLY = set(args)
SIZE = (1600, 1000)
DROP = r'render\(|file\.save|file\.export|image\.save|lightmap|op\("lib\.'


def bees(name, drop=DROP):
    """A walkthrough scene, without its renders and file writes."""
    text = open(os.path.join(SCENES, name)).read()
    return '\n'.join(l for l in text.splitlines() if not re.search(drop, l))


def shoot(name, script, *steps, timeout=900):
    """Runs `script` (BeeScript) in a fresh headless BeeModel, then `steps`
    (console lines, or lists of --shot arguments), and saves the frame."""
    from PIL import Image
    work = tempfile.mkdtemp(prefix='bee-site-')
    src, ppm, log = (os.path.join(work, f) for f in ('scene.bees', 'shot.ppm', 'log.txt'))
    with open(src, 'w') as f:
        f.write(script + '\n')
    cmd = [BIN, '--shot', ppm, '--size', '%d,%d' % SIZE, '--dump-log', log,
           '--op', 'view.toggle_console',                # (more room for the viewport)
           '--op', 'script.run ' + src]
    for s in steps:
        cmd += s if isinstance(s, list) else ['--op', s]
    # the pointer out of the way (no hover highlight), and the toasts gone
    cmd += ['--move', '%d,%d' % (SIZE[0] - 5, SIZE[1] - 5), '--wait', '6000']
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=work)
    if os.path.exists(log):
        for line in open(log, errors='replace'):
            if re.search(r'error|unknown|not available|failed', line, re.I):
                print('  log:', line.strip()[:160])
    if not os.path.exists(ppm):
        print('  no frame:', (r.stdout + r.stderr)[-300:])
        return
    os.makedirs(OUT, exist_ok=True)
    img = Image.open(ppm).convert('RGB')
    img.save(os.path.join(OUT, name + '.png'))
    print('  shot', name, img.size, flush=True)


def tab(name):
    return ['--click-label', 'tab:' + name]


SHOTS = {}


def shot(fn):
    SHOTS[fn.__name__] = fn
    return fn


@shot
def modeling():
    """The studio scene in Material Preview, its material in Properties."""
    shoot('modeling', bees('product_shot.bees') + '\nselect("Paint")\nview(18, 14, 11, 0, 1.3, 0)',
          'view.shading_material', tab('Material'))


@shot
def nodes():
    """The stone material's node graph (Shading workspace)."""
    shoot('nodes', bees('product_shot.bees') + '\nselect("Plinth")',
          'workspace.set Shading', 'view.shading_material', 'view(25, 20, 7, 0, 1, 0)')


@shot
def cad():
    """The parametric enclosure in the CAD workspace."""
    shoot('cad', bees('enclosure.bees') + '\nop("object.select_all")', 'workspace.set CAD',
          'view.toggle_console', 'view.frame_selected')


@shot
def sculpt():
    """The sculpted stone head."""
    shoot('sculpt', bees('sculpt_paint.bees') + '''
op("object.sculpt_mode")
op("object.select_all")
select("Head")
op("object.select_all")''', 'workspace.set Sculpt', 'view.shading_material', 'view(25, 12, 6, 0.4, 0.9, 0)')


@shot
def procedural():
    """The procedural valley: geometry nodes, erosion, scattering, L-systems."""
    shoot('procedural', bees('procedural.bees') + '\nview(30, 28, 70, 0, 0, 0)', 'view.shading_material')


@shot
def fields():
    """A tornado lifting boxes, its streamlines shown."""
    shoot('fields', '''delete("Cube")
op("create.ground")
op("field.add_tornado")
move("Tornado", 0, 0, 0)
seed(4)
for i in 0..60 {
  add("cube", "Box" + i, rand() * 10 - 5, 0.3 + rand() * 4, rand() * 10 - 5)
  scale("Box" + i, 0.15 + rand() * 0.2)
  rotate("Box" + i, rand() * 3, rand() * 3, rand() * 3)
  select("Box" + i)
  op("rigid.add", "active box")
}
add("sphere", "Probe", 3, 0.5, 0)
scale("Probe", 0.4)
select("Probe")
op("view.field_lines")
frame(40)
view(25, 18, 22, 0, 2.5, 0)''', 'view.shading_material', tab('Physics'))


@shot
def landscape():
    """The island preset: eroded, painted by slope and height, a sea."""
    shoot('landscape', '''delete("Cube")
op("landscape.add", "island size 200 seed 3")
op("landscape.layer", "set 0 height 62")
op("landscape.paint", "add sand colour 0.78 0.69 0.5")
op("landscape.paint", "add grass colour 0.22 0.42 0.12 friction 0.7")
op("landscape.paint", "add rock colour 0.36 0.33 0.3 friction 0.8")
op("landscape.paint", "add snow colour 0.95 0.95 0.97")
op("landscape.paint_auto")
op("object.select_all")
view(35, 24, 230, 0, 0, 0)''', 'view.shading_material', tab('Landscape'))


@shot
def animation():
    """The animation walkthrough: a walk cycle, gears, a heap, cloth."""
    shoot('animation', bees('animation.bees', drop=r'render\(|file\.save|sim\.bake|frame\(')
          + '\nframe(60)\nview(30, 15, 14, 0, 1, 0)', 'workspace.set Animation')


@shot
def physics():
    """The wrecking ball demo, mid-swing."""
    shoot('physics', bees('wrecking-ball.bees') + '\nframe(52)', 'view.shading_material', tab('Physics'))


def main():
    for name, fn in SHOTS.items():
        if ONLY and name not in ONLY:
            continue
        print('--', name, flush=True)
        t = time.time()
        try:
            fn()
        except Exception as e:                      # (the next shot still runs)
            print('  failed:', e)
        print('  %.0f s' % (time.time() - t))


if __name__ == '__main__':
    main()
