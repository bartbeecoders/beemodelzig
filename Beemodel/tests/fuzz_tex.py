#!/usr/bin/env python3
"""Damaged MGRF / MUVS / MATS / IMGS / IMGD chunks: .bee files are untrusted. Each
run damages a textured scene and opens it, shows Material Preview, renders and
bakes. The debug binary's safety checks count: only a clean exit passes.
fuzz_tex.py [runs] [seed]; BEEMODEL_BIN picks the binary."""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, random, struct, subprocess, sys, tempfile, zlib

BIN = os.environ.get('BEEMODEL_BIN', './zig-out-debug/bin/beemodel')
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 40
rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261105)
src = open('tests/files/tex_uv.bee', 'rb').read()


def chunks(b):
    o = 8
    out = []
    while o + 8 <= len(b):
        t, s = struct.unpack_from('<4sI', b, o)
        d = b[o + 8:o + 8 + s]
        if t == b'ZCHK':
            tag = d[:4]
            d = zlib.decompress(d[8:], -15)
            t = tag
        out.append([t, bytearray(d)])
        o += 8 + s
    return out


def pack(cs):
    o = bytearray(b'BEEM' + struct.pack('<I', 1))
    for t, d in cs:
        o += t + struct.pack('<I', len(d)) + d
    return bytes(o)


def damage(d):
    k = rng.random()
    if not d:
        return
    if k < 0.45:
        for _ in range(rng.randrange(1, 24)):
            d[rng.randrange(len(d))] = rng.randrange(256)
    elif k < 0.7:
        # 32-bit words that make trouble: NaN, inf, huge counts and links
        for _ in range(rng.randrange(1, 12)):
            o = rng.randrange(max(1, len(d) - 3)) & ~3
            d[o:o + 4] = struct.pack('<I', rng.choice([0x7fc00000, 0x7f800000, 0xff800000, 0xffffffff, 0x10000000, 48, 49, 0x30001, 0xffff, 0x4f000000]))
    elif k < 0.85:
        del d[rng.randrange(len(d)):]
    else:
        d += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 64)))


def tiny_png():
    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    raw = b''.join(b'\0' + bytes([200, 40, 10, 128]) * 4 for _ in range(4))
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')


LAYER = tiny_png()
fails = 0
tmp = tempfile.mkdtemp()
base = chunks(src)
for r in range(runs):
    cs = [[t, bytearray(d)] for t, d in base]
    # vertex colours and paint layers on the first mesh and image, damaged like the rest
    cs.append([b'MVCL', bytearray(struct.pack('<II', 0, 24) + b'\xff' * 96)])
    cs.append([b'ILAY', bytearray(struct.pack('<III', 0, 2, 1) + b''.join(struct.pack('<fIII', 1, k, 1, len(LAYER)) + LAYER for k in range(2)))])
    for t, d in cs:
        if t in (b'MGRF', b'MUVS', b'MATS', b'IMGS', b'IMGD', b'MVCL', b'ILAY') and rng.random() < 0.6:
            damage(d)
    p = os.path.join(tmp, 'd.bee')
    open(p, 'wb').write(pack(cs))
    cmd = [BIN, '--shot', os.path.join(tmp, 'f.ppm'), '--size', '320x240', '--key', 'enter', '--type', 'file.open ' + p, '--key', 'enter',
           '--type', 'view.shading_material', '--key', 'enter', '--type', 'render.settings 16 9 2', '--key', 'enter',
           '--type', 'image.new a 8 8', '--key', 'enter', '--type', 'object.bake Cube Cube ao a', '--key', 'enter', '--wait', '10',
           '--type', 'material.bake Cube 8', '--key', 'enter', '--wait', '10', '--key', 'esc',
           # (the UVs and seams of the damaged MUVS, in the UV editor)
           '--type', 'area.type_uv_editor', '--key', 'enter', '--key', 'esc', '--move', '100,120', '--key', 'd', '--key', 'a', '--key', 'g', '--move', '130,140', '--key', 'enter', '--key', 'd',
           '--key', 'enter', '--type', 'uv.pack', '--key', 'enter', '--type', 'uv.seams_from_sharp', '--key', 'enter', '--type', 'uv.unwrap', '--key', 'enter', '--type', 'area.type_viewport', '--key', 'enter', '--key', 'esc',
           '--move', '100,120', '--key', 'f12', '--render-wait',
           # (and painted)
           '--key', 'enter', '--type', 'mode.texture_paint', '--key', 'enter', '--key', 'esc', '--drag', '100,100,160,140', '--key', 'ctrl+z',
           '--key', 'enter', '--type', 'mode.vertex_paint', '--key', 'enter', '--key', 'esc', '--drag', '100,100,160,140', '--key', 'ctrl+z']
    q = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if q.returncode not in (0, 2):
        fails += 1
        keep = os.path.join(tmp, f'bad{r}.bee')
        os.replace(p, keep)
        print(f'FAIL rc={q.returncode}: {keep}')
        print('\n'.join(q.stderr.splitlines()[-14:]))
print(f'texture fuzz: {runs} damaged files, fails {fails}')
sys.exit(1 if fails else 0)
