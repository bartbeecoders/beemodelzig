#!/usr/bin/env bash
# Texturing, BeeModel on its own, two ways in the same build: a BeeScript
# (--run) and the console's lines (--type). The textured scene the script made
# renders the same from the window (within the renderer's noise, found by
# rendering twice), bakes give the same bytes both ways, saving keeps MUVS,
# MGRF and IMGD (open -> save) and the embedded images' pixels, the material
# commands build the same MATS and MGRF both ways, the OBJ export the same vt.
# tests/texture.sh [binary]
set -uo pipefail
cd "$(dirname "$0")/.."
# a HOME of its own: the user's ~/.config stays as it is
export HOME="$(mktemp -d /tmp/beehome-XXXXXX)"
trap 'rm -rf "$HOME"' EXIT
ZIG=${1:-./zig-out/bin/beemodel}
# (the BeeScript route: the same build)
BS=$ZIG
T=$(mktemp -d /tmp/beemodel-texture.XXXXXX)
fail=0
python3 - "$T" <<'PY'
import math, struct, sys, zlib
d = sys.argv[1]
def png(path, w, h, px):
    raw = b''.join(b'\0' + bytes(c for p in px[y * w:(y + 1) * w] for c in p) for y in range(h))
    def ch(t, b):
        return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
W = 96
png(d + '/set_albedo.png', W, W, [(230 if ((x // 12) + (y // 12)) & 1 else 40, 60 + x * 180 // W, 40 + y * 200 // W) for y in range(W) for x in range(W)])
def nrm(x, y):
    a, b = math.sin(x / W * 2 * math.pi * 4) * .5, math.cos(y / W * 2 * math.pi * 3) * .4
    l = math.sqrt(a * a + b * b + 1)
    return tuple(int((v / l * .5 + .5) * 255 + .5) for v in (a, b, 1))
png(d + '/set_normal.png', W, W, [nrm(x, y) for y in range(W) for x in range(W)])
png(d + '/set_roughness.png', W, W, [(int(255 * (.1 + .8 * ((x // 24) & 1))),) * 3 for y in range(W) for x in range(W)])
png(d + '/set_metallic.png', W, W, [(int(255 * ((y // 24) & 1)),) * 3 for y in range(W) for x in range(W)])
PY
cat > "$T/a.bees" <<E
op("uv.smart_project", "Cube")
op("material.import_textures", "$T/set_albedo.png")
add("sphere", "Ball", 3.2, 0, 0)
op("material.new", "W")
op("material.preset", "wood W")
op("material.assign", "W")
add("cube", "Box", -3.2, 0, 0)
op("uv.smart_project", "Box")
modifier("Box", "subsurf")
op("material.new", "T")
op("material.texture", "T set_albedo 0.5")
op("material.assign", "T")
op("file.save", "$T/s.bee")
op("render.device", "cpu")
render("$T/o1.png", 240, 135, 256, 0)
render("$T/o2.png", 240, 135, 256, 0)
E
"$BS" --run "$T/a.bees" >/dev/null 2>&1 || { echo "texture: the scene's script failed"; exit 1; }
render_port() { # scene out
    "$ZIG" --shot "$T/p.ppm" --key enter --type "file.open $1" --key enter --type "render.device cpu" --key enter --type "render.settings 240 135 256" --key enter \
        --type "render.denoise" --key enter --key esc --move 615,360 --key f12 --render-wait --key enter --type "render.save $2" --key enter >/dev/null 2>&1
}
render_port "$T/s.bee" "$T/z.png" || fail=1
"$ZIG" --shot "$T/p.ppm" --key enter --type "file.open $T/s.bee" --key enter --type "file.save $T/z.bee" --key enter >/dev/null 2>&1 || fail=1
# bakes: a high mesh that shades itself, every map
cat > "$T/c.bees" <<E
op("uv.smart_project", "Cube")
hi = add("sphere", "Hi", 0, 0, 0)
scale(hi, 1.3, 1.3, 1.3)
modifier("Hi", "array")
modset("Hi", 0, "x", 1.2)
op("material.new", "M")
op("material.preset", "concrete M")
select("Cube")
op("material.assign", "M")
op("file.save", "$T/k.bee")
op("image.new", "n 96 96")
op("image.new", "a 96 96")
op("image.new", "c 96 96")
op("object.bake", "Cube Hi normal n")
op("object.bake", "Cube Hi ao a 1.5")
op("object.bake", "Cube Hi curvature c")
op("material.bake", "Cube 96 apply")
op("image.save", "n $T/o_n.png")
op("image.save", "a $T/o_a.png")
op("image.save", "c $T/o_c.png")
op("image.save", "M_base $T/o_M_base.png")
op("image.save", "M_orm $T/o_M_orm.png")
op("image.save", "M_normal $T/o_M_normal.png")
op("image.save", "M_emissive $T/o_M_emissive.png")
op("file.save", "$T/ko.bee")
E
"$BS" --run "$T/c.bees" 2>&1 | grep -a "^error" && { echo "texture: the script's bake failed"; fail=1; }
args=(--key enter --type "file.open $T/k.bee" --key enter)
for n in n a c; do args+=(--type "image.new $n 96 96" --key enter); done
args+=(--type "object.bake Cube Hi normal n" --key enter --wait 10 --type "object.bake Cube Hi ao a 1.5" --key enter --wait 10
       --type "object.bake Cube Hi curvature c" --key enter --wait 10 --type "material.bake Cube 96 apply" --key enter --wait 10)
for n in n a c M_base M_orm M_normal M_emissive; do args+=(--type "image.save $n $T/z_$n.png" --key enter); done
args+=(--type "file.save $T/kz.bee" --key enter)
"$ZIG" --shot "$T/p.ppm" "${args[@]}" >/dev/null 2>&1 || fail=1
echo "op(\"file.open\", \"$T/kz.bee\"); print(imgpixel(\"M_base\", 20, 20, 0), imgpixel(\"M_base\", 20, 20, 3), imgpixel(\"M_normal\", 30, 21, 1), imgpixel(\"a\", 40, 40, 0))" > "$T/d.bees"
echo "op(\"file.open\", \"$T/ko.bee\"); print(imgpixel(\"M_base\", 20, 20, 0), imgpixel(\"M_base\", 20, 20, 3), imgpixel(\"M_normal\", 30, 21, 1), imgpixel(\"a\", 40, 40, 0))" > "$T/e.bees"
a=$("$BS" --run "$T/d.bees" 2>&1 | tail -1)
b=$("$BS" --run "$T/e.bees" 2>&1 | tail -1)
if [[ -n "$a" && "$a" != *error* && "$a" == "$b" ]]; then echo "embedded images, saved and opened again: ok ($a)"; else echo "embedded images: FAILED: '$a' / '$b'"; fail=1; fi
python3 - "$T" <<'PY' || fail=1
import struct, sys, zlib
d = sys.argv[1]
def png(path):
    b = open(path, 'rb').read(); o = 8; idat = b''
    while o < len(b):
        l, t = struct.unpack_from('>I4s', b, o)
        if t == b'IHDR': w, h, _, ct = struct.unpack_from('>IIBB', b, o + 8)
        if t == b'IDAT': idat += b[o + 8:o + 8 + l]
        o += 12 + l
    r = zlib.decompress(idat); n = {2: 3, 6: 4}[ct]; st = w * n + 1; prev = bytearray(w * n); px = []
    for y in range(h):
        f = r[y * st]; line = bytearray(r[y * st + 1:(y + 1) * st])
        for i in range(w * n):
            a = line[i - n] if i >= n else 0; u = prev[i]; c = prev[i - n] if i >= n else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + u) & 255
            elif f == 3: line[i] = (line[i] + (a + u) // 2) & 255
            elif f == 4:
                p = a + u - c; pa = abs(p - a); pb = abs(p - u); pc = abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else u if pb <= pc else c)) & 255
        px.append(bytes(line)); prev = line
    return w, h, n, px
def diff(a, b):
    p, q = png(a), png(b)
    if p[:2] != q[:2]: return 1e9, 1e9
    w, h, n, m = p[0], p[1], p[2], q[2]
    tot = 0; blocks = {}
    for y in range(h):
        for x in range(w):
            for c in range(3):
                u, v = p[3][y][x * n + c], q[3][y][x * m + c]
                tot += abs(u - v)
                e = blocks.setdefault((x // 8, y // 8, c), [0, 0])
                e[0] += u - v; e[1] += 1
    return tot / (w * h * 3), max(abs(e[0]) / e[1] for e in blocks.values())
ok = True
noise, nb = diff(d + '/o1.png', d + '/o2.png')
m, b = diff(d + '/o1.png', d + '/z.png')
print(f'render: the window against the script: mean {m:.3f}, worst block {b:.2f} /255 (the script against itself: {noise:.3f}, {nb:.2f})')
w, h, n, px = png(d + '/z.png')
flat = len({bytes(r[x * n:x * n + 3]) for r in px for x in range(w)}) < 50
if flat or not (m <= max(noise * 1.25, 0.5) and b <= max(nb * 2, 2)):
    print('render: FAILED' + (' (next to nothing drawn)' if flat else '')); ok = False
# saved and opened again: the textures' chunks the same
def chunks(p):
    b = open(p, 'rb').read(); o = 8; c = {}
    while o + 8 <= len(b):
        t, s = struct.unpack_from('<4sI', b, o)
        if t == b'ZCHK':
            tag = b[o + 8:o + 12]; c[tag] = zlib.decompress(b[o + 16:o + 8 + s], -15)
        else:
            c[t] = b[o + 8:o + 8 + s]
        o += 8 + s
    return c
a, z = chunks(d + '/s.bee'), chunks(d + '/z.bee')
for t in (b'MUVS', b'MGRF', b'IMGD'):
    if t not in a or a.get(t) != z.get(t):
        print(f'open -> save: FAILED, {t.decode()} ' + ('not there' if t not in a else 'differs')); ok = False
    else:
        print(f'open -> save: {t.decode()} the same ({len(a[t])} bytes)')
for n in ('n', 'a', 'c', 'M_base', 'M_orm', 'M_normal', 'M_emissive'):
    m, _ = diff(f'{d}/o_{n}.png', f'{d}/z_{n}.png')
    # (a texel on the seam of two triangles goes to whichever thread writes last)
    if m > 0.01:
        print(f'bake {n}: FAILED, differs by {m:.4f} /255'); ok = False
    else:
        print(f'bake {n}: ok' + (', the same bytes' if m == 0 else f', differs by {m:.5f} /255'))
sys.exit(0 if ok else 1)
PY
# what the commands build: the same bytes (MATS, MGRF) by a script and by the console
cmds=("material.new A" "material.preset wood A" "material.new B" "material.preset marble B" "material.new C" "material.preset concrete C"
      "material.new D" "material.preset fabric D" "material.new E" "material.preset leather E" "material.import_textures $T/set_albedo.png"
      "material.new G" "material.node G texcoord 2 3" "material.node G scalarparam Wear 0.25" "material.node G checker 3" "material.link G 1 3 1 1" "material.socket G roughness 2"
      "material.node G image set_albedo 2 1 1" "material.node_set G 3 2 0.1 0.2 0.3" "material.instance G H" "material.param H Wear 0.75"
      "material.function_new Fn" "material.texture A none" "material.preset wood A")
: > "$T/g.bees"; args=(--key enter)
for c in "${cmds[@]}"; do
    id=${c%% *}; rest=${c#* }
    echo "op(\"$id\", \"$rest\")" >> "$T/g.bees"
    args+=(--type "$c" --key enter --wait 10)
done
echo "op(\"file.save\", \"$T/go.bee\")" >> "$T/g.bees"
args+=(--type "file.save $T/gz.bee" --key enter)
"$BS" --run "$T/g.bees" 2>&1 | grep -a "^error"
"$ZIG" --shot "$T/p.ppm" "${args[@]}" >/dev/null 2>&1 || fail=1
python3 - "$T" <<'PY' || fail=1
import struct, sys, zlib
def chunks(p):
    b = open(p, 'rb').read(); o = 8; c = {}
    while o + 8 <= len(b):
        t, s = struct.unpack_from('<4sI', b, o)
        if t == b'ZCHK':
            tag = b[o + 8:o + 12]; c[tag] = zlib.decompress(b[o + 16:o + 8 + s], -15)
        else:
            c[t] = b[o + 8:o + 8 + s]
        o += 8 + s
    return c
d = sys.argv[1]
a, b = chunks(d + '/go.bee'), chunks(d + '/gz.bee')
ok = True
for t in (b'MATS', b'MGRF'):
    same = a[t] == b[t]
    print(f'commands {t.decode()}: {len(a[t])} bytes' + (', the same both ways' if same else ', FAILED'))
    if not same:
        ok = False
        print('  first difference at', next((i for i, (x, y) in enumerate(zip(a[t], b[t])) if x != y), None), len(a[t]), len(b[t]))
sys.exit(0 if ok else 1)
PY
# OBJ: a vt per loop, faces v/vt
echo "op(\"file.open\", \"$T/s.bee\"); op(\"file.export_obj\", \"$T/o.obj\")" > "$T/f.bees"
"$BS" --run "$T/f.bees" >/dev/null 2>&1
"$ZIG" --shot "$T/p.ppm" --key enter --type "file.open $T/s.bee" --key enter --type "file.export_obj $T/z.obj" --key enter --wait 10 >/dev/null 2>&1 || fail=1
python3 - "$T" <<'PY' || fail=1
import sys
d = sys.argv[1]
def load(p):
    vt = []; f = []
    for l in open(p):
        w = l.split()
        if not w: continue
        if w[0] == 'vt': vt.append((float(w[1]), float(w[2])))
        if w[0] == 'f': f.append([tuple(c.split('/')) for c in w[1:]])
    return vt, f
a, fa = load(d + '/o.obj'); b, fb = load(d + '/z.obj')
same = len(a) == len(b) and all(abs(x[0] - y[0]) < 2e-5 and abs(x[1] - y[1]) < 2e-5 for x, y in zip(a, b)) and fa == fb
print(f'OBJ: {len(a)} vt, {len(b)} vt' + (', the same' if same and a else ': FAILED'))
sys.exit(0 if same and a else 1)
PY
rm -rf "$T"
exit $fail
