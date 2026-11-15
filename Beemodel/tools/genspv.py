#!/usr/bin/env python3
"""Compile the GPU helper's shaders (src/gpu/*.comp, view.vert, view.frag: GLSL) to SPIR-V with glslc,
into src/gpu/spv/*.spv. The output is committed and embedded in the helper, so
building it needs no shader compiler. `zig build shaders` runs this.

    python3 tools/genspv.py [name ...]
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GPU = os.path.join(HERE, '..', 'src', 'gpu')
# (name, source, defines, target): ptg is pt.comp with shader graphs; ptr and
# ptgr trace with ray queries (RTX, Vulkan 1.2); asprep feeds their builds
SHADERS = [('pt', 'pt.comp', [], '1.1'), ('ptg', 'pt.comp', ['-DGRAPHS'], '1.1'),
           ('ptr', 'pt.comp', ['-DRTX'], '1.2'), ('ptgr', 'pt.comp', ['-DGRAPHS', '-DRTX'], '1.2'),
           ('asprep', 'asprep.comp', [], '1.1'), ('raster', 'raster.comp', [], '1.1'),
           ('viewv', 'view.vert', [], '1.1'), ('viewf', 'view.frag', [], '1.1')]

only = set(sys.argv[1:])
os.makedirs(os.path.join(GPU, 'spv'), exist_ok=True)
for name, src, defs, env in SHADERS:
    if only and name not in only:
        continue
    out = os.path.join(GPU, 'spv', name + '.spv')
    subprocess.run(['glslc', '-O', '--target-env=vulkan' + env] + defs + ['-o', out, os.path.join(GPU, src)], check=True)
    print(name, os.path.getsize(out))
