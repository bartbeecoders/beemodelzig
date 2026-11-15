#!/usr/bin/env python3
"""Light probes and the lightmap: a scene baked (PRBE coefficients and the LMAP
UVs and atlas finite and in range, the bake against a trace of the same points),
the .bee read back and written again the same, undo, and damaged chunks that
must not crash.

    BEEMODEL_BIN=zig-out-debug/bin/beemodel tests/bake.py [damage-runs=200] [seed]

Bakes run in the binary given; use a release one for the numbers to come quickly.
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import atexit, math, os, random, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(os.environ.get("BEEMODEL_BIN", os.path.join(HERE, "..", "zig-out-debug", "bin", "beemodel")))
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 200
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
T = tempfile.mkdtemp(prefix="bake-", dir="/tmp")  # (headless, BeeModel writes under /tmp only)
atexit.register(shutil.rmtree, T, True)
PR = 81920
fails = 0


def check(ok, msg):
    global fails
    print(("  ok   " if ok else "  FAIL ") + msg)
    fails += 0 if ok else 1


def chunks(path):
    d = open(path, "rb").read()
    o, out = 8, []
    while o + 8 <= len(d):
        t, s = struct.unpack_from("<4sI", d, o)
        c = d[o + 8 : o + 8 + s]
        if t == b"ZCHK":
            t, c = c[:4], zlib.decompress(c[8:], -15)
        out.append((t, c))
        o += 8 + s
    return out


def chunk(path, tag):
    return dict(chunks(path)).get(tag)


def probes(c):
    n = struct.unpack_from("<I", c)[0]
    return [c[4 + i * PR : 4 + (i + 1) * PR] for i in range(n)]


def floats(b, off, n):
    return struct.unpack_from("<%df" % n, b, off)


def lmap(c):
    w, h, n = struct.unpack_from("<3I", c)
    es, o = [], 12
    for _ in range(n):
        uid, nl, nt = struct.unpack_from("<3I", c, o)
        es.append(dict(uid=uid, nl=nl, nt=nt, rect=floats(c, o + 12, 4)))
        o += 28
    for e in es:
        e["uv"] = floats(c, o, e["nl"] * 2)
        o += e["nl"] * 8
    return w, h, es, floats(c, o, w * h * 3), o + w * h * 12 == len(c)


def rel_rms(a, b):
    r = math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)) / len(a))
    return r / (sum(abs(x) for x in a) / len(a))


def port(*cmds, dump=None):
    args = [BIN, "--shot", os.path.join(T, "x.ppm"), "--size", "1280x800"]
    for c in cmds:
        args += ["--key", "enter", "--type", c, "--key", "enter"]
    if dump:
        args += ["--dump-ui", dump]
    return subprocess.run(args, capture_output=True, text=True, timeout=600)


def bee(code):
    p = os.path.join(T, "s.bees")
    open(p, "w").write(code)
    return subprocess.run([BIN, "--run", p], capture_output=True, text=True, timeout=600)


# (the lighting scene, the panel 10 cm up: resting on the floor
# its bottom face ties with the floor, and which wins depends on the BVH's order)
SCENE = """delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 12)
add("cube", "Roof", 0, 2, 0)
scale("Roof", 3, 0.1, 3)
add("cube", "Panel", 7, 1.6, 0)
scale("Panel", 0.1, 1.5, 2)
material("Red")
matset("Red", "base", 0.8, 0.1, 0.1)
matset("Red", "emission", 1, 0.05, 0.05)
matset("Red", "strength", 8)
assign("Panel", "Red")
add("sphere", "Ball", 5, 1, 2)
scale("Ball", 0.6)
material("Mirror")
matset("Mirror", "base", 0.95, 0.95, 0.95)
matset("Mirror", "metallic", 1)
matset("Mirror", "roughness", 0.05)
assign("Ball", "Mirror")
"""
ADD = ("probe.add irradiance 0 1 0 9 0.9 9 7 3 7", "probe.add reflection 5 1.5 0 2.5 1.5 3")
RAYS, LM, LR = 16384, 256, 256

scene = os.path.join(T, "scene.bee")
pbee = os.path.join(T, "p.bee")
r = bee(SCENE + f'op("file.save", "{scene}")\n')
check(r.returncode == 0 and os.path.exists(scene), "the scene script runs and saves")
r = port(f"file.open {scene}", *ADD, f"probe.bake {RAYS}", f"lightmap.bake {LM} {LR}", f"file.save {pbee}")
check(r.returncode == 0 and os.path.exists(pbee), "it bakes and saves")
pp = probes(chunk(pbee, b"PRBE"))
check(len(pp) == 2, "two probes")
n = 7 * 3 * 7
a = floats(pp[0], 256, n * 27)
check(all(math.isfinite(v) for v in a) and all(a[i] > 0 for i in range(0, len(a), 27)), "irradiance: finite, the first band above zero everywhere")
N = 6 * 32 * 32 * 3
a = floats(pp[1], 256, N)
check(all(math.isfinite(v) and v >= 0 for v in a) and any(a), "reflection cube: finite, not negative, not all black")
wp, hp, ep, ap, okp = lmap(chunk(pbee, b"LMAP"))
check(okp and (wp, hp) == (LM, LM), "LMAP sizes add up")
check(len(ep) == 4 and all(x["nl"] > 0 and x["nt"] > 0 for x in ep), f"four objects in the lightmap, each with loops and triangles ({[(x['nl'], x['nt']) for x in ep]})")
check(all(0 <= v <= 1 for x in ep for v in x["uv"]) and all(0 <= v <= 1 for x in ep for v in x["rect"]), "second UVs and regions inside the atlas")
check(all(math.isfinite(v) and v >= 0 for v in ap) and sum(1 for v in ap if v) > len(ap) // 10, "the atlas: finite, not negative, lit")
# its own file read back: the probes, the lightmap, and the bake against a trace
out = bee(f'op("file.open", "{pbee}")\n'
          'print(probe(0), probe(1), probe(6), lightmap(0), lightmap(1))\n'
          'print(probesample(0, 0, 0.1, 7.5, 0, 1, 0, 2), probesample(2, 0, 0.1, 7.5, 0, 1, 0, 2, 16384))\n'
          'print(probesample(0, 6, 1, 0, 1, 0, 0, 0), probesample(2, 6, 1, 0, 1, 0, 0, 0, 16384))\n'
          'print(lmsample("Floor", 6, 0, 0, 0), probesample(2, 6, 0, 0, 0, 1, 0, 0, 16384))\n'
          'print(lmsample("Floor", 0, 0, 0, 2), probesample(2, 0, 0, 0, 0, 1, 0, 2, 16384))\n'
          'print(lmsample("Roof", 0, 2.1, 0, 1) > 0.3)\n').stdout.strip().splitlines()
check(out and out[0].split() == ["2", "2", "147", "4", str(LM)], f"it opens its own file ({out[:1]})")
for line in out[1:5]:
    try:
        g, want = map(float, line.split())
    except ValueError:
        g, want = float("nan"), 0
    check(abs(g - want) <= 0.12 * max(want, 0.05), f"the bake gives {g:.4f}, traced {want:.4f}")
check(out[5:] == ["1"], "the roof's region is found in the atlas")
# save -> open -> save: the same chunks
back = os.path.join(T, "back.bee")
r = port(f"file.open {pbee}", f"file.save {back}")
check(r.returncode == 0 and chunk(back, b"PRBE") == chunk(pbee, b"PRBE"), "PRBE file -> open -> file: byte for byte")
x, y = lmap(chunk(pbee, b"LMAP")), lmap(chunk(back, b"LMAP"))
check(len(chunk(pbee, b"LMAP")) == len(chunk(back, b"LMAP")) and x[3] == y[3] and [e["uv"] for e in x[2]] == [e["uv"] for e in y[2]]
      and [e["rect"] for e in x[2]] == [e["rect"] for e in y[2]], "LMAP file -> open -> file: the UVs, regions, atlas")
out = bee(f'op("file.open", "{back}")\nprint(lightmap(0), lmsample("Floor", 6, 0, 0, 0) > 1, lmsample("Roof", 0, 2.1, 0, 1) > 0.3)\n').stdout.strip()
check(out == "4 1 1", f"the regions still find their objects after the file is opened again ({out})")
# the material preview on the baked file: it shows
r = subprocess.run([BIN, "--shot", os.path.join(T, "v.ppm"), "--size", "1280x800", "--key", "enter", "--type", f"file.open {pbee}", "--key", "enter",
                    "--type", "view.toggle_material_preview", "--key", "enter"], capture_output=True, text=True, timeout=300)
check(r.returncode == 0 and os.path.getsize(os.path.join(T, "v.ppm")) > 1000, f"the material preview of the baked file draws (exit {r.returncode})")
base = pbee

# undo: the probes come and go with the steps; the lightmap stays (baked data, like a render)
u = os.path.join(T, "u.bee")
port(*ADD, "lightmap.bake 64 2", "undo", f"file.save {u}")
check(len(probes(chunk(u, b"PRBE"))) == 1 and lmap(chunk(u, b"LMAP"))[0] == 64, "undo takes a probe back, not the lightmap")
port(*ADD, "undo", "redo", f"file.save {u}")
check(len(probes(chunk(u, b"PRBE"))) == 2, "redo brings it again")
port(*ADD, "probe.remove 1", "probe.bake 8", "undo", f"file.save {u}")
p = probes(chunk(u, b"PRBE"))
check(len(p) == 1 and struct.unpack_from("<I", p[0], 4)[0] == 0, "undo takes a bake back")
port(*ADD, "probe.clear", "lightmap.clear", f"file.save {u}")
check(chunk(u, b"PRBE") == bytes(4) and chunk(u, b"LMAP") == bytes(4), "cleared: both chunks hold a zero")
port(*ADD, "lightmap.bake 64 2", "file.new", f"file.save {u}")
check(chunk(u, b"PRBE") == bytes(4) and chunk(u, b"LMAP") == bytes(4), "file.new forgets both")
png, exr = os.path.join("/tmp", os.path.basename(T) + ".png"), os.path.join("/tmp", os.path.basename(T) + ".exr")
port("lightmap.bake 64 2", f"lightmap.save {png}", f"lightmap.save {exr}")
hp = open(png, "rb").read(8) if os.path.exists(png) else b""
he = open(exr, "rb").read(4) if os.path.exists(exr) else b""
check(hp == b"\x89PNG\r\n\x1a\n" and he == b"\x76\x2f\x31\x01", "lightmap.save writes PNG and OpenEXR")
for f in (png, exr):
    if os.path.exists(f):
        os.remove(f)

# damage: bytes changed, cut or blown up in PRBE and LMAP; the file opens, shows, saves, or says no
rng = random.Random(SEED)
cs = chunks(base)
crashes = 0
special = [0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x7f800000, 0x7fc00000, 0xff800000, 4097, 129, 17]
for run in range(RUNS):
    out = bytearray(b"BEEM" + struct.pack("<I", 1))
    target = rng.choice([b"PRBE", b"LMAP"])
    for t, c in cs:
        c = bytearray(c)
        if t == target and len(c) >= 4:
            for _ in range(rng.choice([1, 2, 8, 64])):
                # the headers mostly: that is where the sizes are
                at = rng.randrange(0, min(len(c) - 3, 400)) if rng.random() < 0.8 else rng.randrange(0, len(c) - 3)
                at &= ~3
                c[at : at + 4] = struct.pack("<I", rng.choice(special))
            if rng.random() < 0.2:
                c = c[: rng.randrange(len(c))]
        out += t + struct.pack("<I", len(c)) + c
    p = os.path.join(T, "d.bee")
    open(p, "wb").write(out)
    r = subprocess.run([BIN, "--shot", os.path.join(T, "d.ppm"), "--size", "640x420", "--key", "enter", "--type", f"file.open {p}", "--key", "enter",
                        "--move", "300,200", "--key", "z", "--type", "view.toggle_material_preview", "--key", "enter", "--type", f"lightmap.save {T}/d.png", "--key", "enter",
                        "--type", f"lightmap.save {T}/d.exr", "--key", "enter", "--type", f"file.save {T}/d2.bee", "--key", "enter"], capture_output=True, text=True, timeout=120)
    if r.returncode not in (0, 2):
        crashes += 1
        keep = f"/tmp/bake-crash{crashes}.bee"
        os.rename(p, keep)
        print("CRASH", r.returncode, keep, "\n".join(r.stderr.splitlines()[-10:]))
check(crashes == 0, f"{RUNS} damaged files (seed {SEED}): {crashes} crashes")
print("== bake: " + ("ok" if not fails else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
