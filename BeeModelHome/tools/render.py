#!/usr/bin/env python3
"""Path-traced renders for the website, made by BeeModel itself: the Zig build,
headless (--run), on the scenes in scenes/ with their own cameras, rendered
larger and with more samples.

  python3 BeeModelHome/tools/render.py [path/to/beemodel] [name ...]
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.abspath(os.path.join(HERE, '..'))
ROOT = os.path.abspath(os.path.join(HOME, '..'))
OUT = os.path.abspath(os.path.join(HERE, '..', 'media', 'renders'))
args = sys.argv[1:]
BIN = os.path.abspath(args.pop(0)) if args and '/' in args[0] else os.path.join(ROOT, 'Beemodel', 'zig-out', 'bin', 'beemodel')
ONLY = set(args)

# name: (scene file, width, height, samples, extra BeeScript before the render)
RENDERS = {
    'studio': ('product_shot.bees', 1920, 1080, 256, ''),
    'sculpt': ('sculpt_paint.bees', 1600, 900, 192, ''),
    'valley': ('procedural.bees', 1920, 1080, 128, ''),
    'gallery': ('gallery-smash.bees', 1600, 900, 128, 'frame(1)\n'),
    'particles': ('dam-break.bees', 1600, 1000, 128, 'for f in 2..41 { frame(f) }\n'),
}


def scene(path):
    text = open(os.path.join(HOME, 'scenes', path)).read()
    keep = []
    for line in text.splitlines():
        if re.search(r'^\s*render\(|file\.save|file\.export|image\.save', line):
            continue
        keep.append(line)
    return '\n'.join(keep)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (path, w, h, spp, extra) in RENDERS.items():
        if ONLY and name not in ONLY:
            continue
        home = tempfile.mkdtemp(prefix='bee-site-render-')
        os.makedirs(os.path.join(home, 'BeeModel'))
        out = os.path.join(OUT, name + '.png')
        code = scene(path) + '\n' + extra + 'print("ms", render("%s", %d, %d, %d, 1))\n' % (out, w, h, spp)
        src = os.path.join(home, 'scene.bees')
        with open(src, 'w') as f:
            f.write(code)
        r = subprocess.run([BIN, '--run', src], env=dict(os.environ, HOME=home, XDG_CACHE_HOME=''),
                           capture_output=True, text=True, timeout=3600)
        ms = [l for l in r.stdout.splitlines() if l.startswith('ms ')]
        print(name, ms[-1] if ms else r.stdout[-300:] + r.stderr[-300:], flush=True)


if __name__ == '__main__':
    main()
