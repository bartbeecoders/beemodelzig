#!/usr/bin/env python3
"""Virtualized geometry, BeeModel alone: the same meshes built two ways (a
BeeScript and the console; VGEO chunks compared byte by byte, level by
level), each route reading the other's file, cuts at several distances,
images of a cut against the full mesh, cracks, the background build,
streaming, damaged chunks that must not crash.

    python3 tests/vgeo.py [BIN] [damage-runs=60] [seed] [--shots DIR]

BIN defaults to $BEEMODEL_BIN, then zig-out-debug/bin/beemodel. A release
binary gives the numbers sooner; damaged chunks want the debug one.
"""
import atexit, os, random, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
args = [a for a in sys.argv[1:]]
BIN = os.environ.get("BEEMODEL_BIN", os.path.join(HERE, "..", "zig-out-debug", "bin", "beemodel"))
if args and not args[0].lstrip("-").isdigit() and args[0] != "--shots":
    BIN = args.pop(0)
BIN = os.path.abspath(BIN)
SHOTS = None
if "--shots" in args:
    i = args.index("--shots")
    SHOTS = args[i + 1]
    del args[i : i + 2]
    os.makedirs(SHOTS, exist_ok=True)
RUNS = int(args[0]) if len(args) > 0 else 60
SEED = int(args[1]) if len(args) > 1 else random.randrange(1 << 30)
T = tempfile.mkdtemp(prefix="vgeo-", dir="/tmp")  # (headless, the port writes under /tmp only)
if not os.environ.get("VGEO_KEEP"): atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME=os.path.join(T, "cache"))
fails = 0
VH = 1024


def check(ok, msg):
    global fails
    print(("  ok   " if ok else "  FAIL ") + msg)
    fails += 0 if ok else 1


def script(code):
    """A BeeScript run by BeeModel (--run, no window): its printed lines."""
    p = os.path.join(T, "o.bees")
    open(p, "w").write(code)
    r = subprocess.run([BIN, "--run", p], capture_output=True, text=True, timeout=600, env=ENV, cwd=T)
    if r.returncode:
        print(r.stdout[-800:], r.stderr[-800:])
    return r.stdout.strip().splitlines()


def port(*cmds, size="1280x800", shot=None, extra=()):
    """Console commands, one by one; returns the console's lines."""
    a = [BIN, "--shot", shot or os.path.join(T, "p.ppm"), "--size", size, "--dump-log", os.path.join(T, "p.log")]
    for c in cmds:
        if c.startswith("--"):
            a += c.split(" ", 1)
        else:
            a += ["--key", "enter", "--type", c, "--key", "enter"]
    a += list(extra)
    r = subprocess.run(a, capture_output=True, text=True, timeout=600, cwd=ROOT)
    if r.returncode not in (0, 2):
        print("port rc", r.returncode, r.stderr[-1500:])
    return r, open(os.path.join(T, "p.log")).read().splitlines()


def chunks(path):
    d = open(path, "rb").read()
    o, out = 8, []
    while o + 8 <= len(d):
        t, s = struct.unpack_from("<4sI", d, o)
        out.append((t, o + 8, s))
        o += 8 + s
    return d, out


def vgeos(path):
    """hash -> (mesh index, block offset in the file, block)"""
    d, cs = chunks(path)
    r = {}
    for t, o, s in cs:
        if t != b"VGEO":
            continue
        ix, pad = struct.unpack_from("<II", d, o)
        b = d[o + 8 + pad : o + s]
        r[struct.unpack_from("<Q", b, 48)[0]] = (ix, o + 8 + pad, b)
    return r


def head(b):
    ncl, ngr, nlv, stri, svert = struct.unpack_from("<5I", b, 12)
    return dict(ncl=ncl, ngr=ngr, nlv=nlv, stri=stri, svert=svert, roots=struct.unpack_from("<I", b, 68)[0],
                lv=[struct.unpack_from("<IIIf", b, 128 + 16 * i) for i in range(nlv)])


def masked(b):
    """All but the build time, the references, the radii."""
    x = bytearray(b)
    x[8:12] = bytes(4)
    x[56:60] = bytes(4)
    x[124:128] = bytes(4)
    x[128 + 16 * head(b)["nlv"] : 512] = bytes(512 - 128 - 16 * head(b)["nlv"])  # (unused level slots)
    for i in range(head(b)["ncl"]):
        o = VH + 64 * i + 12
        x[o : o + 4] = bytes(4)
    return bytes(x)


def set_view(src, dst, yaw, pitch, dist, tgt=(0, 0, 0)):
    d, cs = chunks(src)
    d = bytearray(d)
    for t, o, s in cs:
        if t == b"VIEW":
            struct.pack_into("<3f3f", d, o + 12, yaw, pitch, dist, *tgt)
    open(dst, "wb").write(d)


def ppm(path):
    import numpy as np
    d = open(path, "rb").read()
    p = d.split(b"\n", 3)
    w, h = map(int, p[1].split())
    return np.frombuffer(p[3], dtype=np.uint8).reshape(h, w, 3)


SCENE = """
n = add("torus", "T")
modifier(n, "subsurf"); modset(n, 0, "levels", 4); modapply(n, 0)
n = add("grid", "G", 8, 0, 0)
modifier(n, "subsurf"); modset(n, 0, "levels", 3); modapply(n, 0)
n = add("cube", "C", -8, 0, 0)
modifier(n, "array"); modset(n, 0, "count", 200); modapply(n, 0)
n = add("cylinder", "Y", 0, 0, 8)
op("file.save", "%(src)s")
select("T"); op("vgeo.build")
print("v", "T", vgeo("T", 0), vgeo("T", 1), vgeo("T", 2), vgeo("T", 3), vgeo("T", 4), vgeo("T", 5), vgeo("T", 9), vgeo("T", 12))
select("G"); op("vgeo.build")
print("v", "G", vgeo("G", 0), vgeo("G", 1), vgeo("G", 2), vgeo("G", 3), vgeo("G", 4), vgeo("G", 5), vgeo("G", 9), vgeo("G", 12))
select("C"); op("vgeo.build")
print("v", "C", vgeo("C", 0), vgeo("C", 1), vgeo("C", 2), vgeo("C", 3), vgeo("C", 4), vgeo("C", 5), vgeo("C", 9), vgeo("C", 12))
select("Y"); op("vgeo.build")
print("v", "Y", vgeo("Y", 0), vgeo("Y", 1), vgeo("Y", 2), vgeo("Y", 3), vgeo("Y", 4), vgeo("Y", 5), vgeo("Y", 9), vgeo("Y", 12))
op("file.save", "%(a)s")
"""


def infos(lines):
    return [l for l in lines if l.startswith("vgeo ")]


def main():
    global fails
    src, a, b, c = [os.path.join(T, x) for x in ("src.bee", "a.bee", "b.bee", "c.bee")]
    print("== the same DAG by a script and by the console")
    out = script(SCENE % dict(src=src, a=a))
    st = [l.split() for l in out if l.startswith("v ")]
    check(len(st) == 4 and all(x[2] == "2" for x in st), "the script built four DAGs: %s" % st)
    build = []
    for k in "TGCY":
        build += ["--click-label row:" + k, "vgeo.build", "vgeo.view info"]
    r, log = port("file.open " + src, *build, "file.save " + b, size="1400x1600")
    A, B = vgeos(a), vgeos(b)
    check(len(A) == 4 and sorted(A) == sorted(B), "four chunks, the same mesh hashes (%d, %d)" % (len(A), len(B)))
    for h in A:
        ha, hb = head(A[h][2]), head(B[h][2]) if h in B else None
        check(ha == hb, "levels: %s" % " ".join("%d/%d" % (l[1], l[2]) for l in ha["lv"]))
        check(h in B and masked(A[h][2]) == masked(B[h][2]), "%d bytes alike (%d clusters, %d triangles): but the radii, the time" % (len(A[h][2]), ha["ncl"], ha["stri"]))
        check(B[h][1] % 4096 == 0, "the block on a page of the file")
    print("== each route reads the other's file")
    vs = []
    for k in "TGCY":
        vs.append('vgeo("%s", 0), vgeo("%s", 1), vgeo("%s", 2), vgeo("%s", 12)' % (k, k, k, k))
    out = script('op("file.open", "%s")\n' % b + "\n".join("print(%s)" % v for v in vs) + '\nop("file.save", "%s")' % c)
    ok = [l.split() for l in out[-4:]]
    want = [(str(head(A[h][2])["ncl"]), str(head(A[h][2])["nlv"])) for h in A]
    check(len(ok) == 4 and all(x[0] == "2" for x in ok) and [x[3] for x in ok] == [x[-1] for x in st], "a script reads the console's: ready, the same crack checks: %s" % ok)
    check(sorted((x[1], x[2]) for x in ok) == sorted(want), "  with the same counts")
    C = vgeos(c)
    check(sorted(C) == sorted(A) and all(masked(C[h][2]) == masked(A[h][2]) for h in A), "  and saves them again, unchanged")
    r, log = port("file.open " + a, *sum([["--click-label row:" + k, "vgeo.view info"] for k in "TGCY"], []), "file.save " + c, size="1400x1600")
    got = [l.split() for l in infos(log)]
    check(len(got) == 4 and [x[12] for x in got] == [x[-1] for x in st], "the console reads the script's: the same crack checks (%s)" % [x[12] for x in got])
    C = vgeos(c)
    check(sorted(C) == sorted(A) and all(masked(C[h][2]) == masked(A[h][2]) for h in A), "  and saves them again, unchanged")
    check("lossy" not in " ".join(log) and any("Saved c.bee" in l for l in log), "  nothing lost")

    print("== cuts at five distances")
    cuts(a)
    print("== the image of a cut, the error it may show")
    images(b)
    print("== cracks")
    cracks(b)
    print("== what does not match goes through the full mesh")
    stale(b)
    print("== modifiers: the evaluated mesh")
    modified()
    print("== extract, proxy")
    extract_proxy()
    print("== the background build")
    background(src)
    print("== streaming")
    streaming(b)
    print("== damaged chunks (%d runs, seed %d)" % (RUNS, SEED))
    damage(b)


def cuts(a):
    for dist in (60.0, 24.0, 10.0, 5.0, 2.5):
        v = os.path.join(T, "v.bee")
        set_view(a, v, 35 * 3.14159265 / 180, 25 * 3.14159265 / 180, dist)
        r, log = port("file.open " + v, "--wait 50", "--key esc", "--move 615,360", "--wait 50", "--bench 4", "vgeo.view stats")
        sp = [l for l in log if l.startswith("vgstat")]
        sp = [float(x) for x in sp[-1].split()[1:]] if sp else []
        if SHOTS:
            shutil.copy(os.path.join(T, "p.ppm"), os.path.join(SHOTS, "cut_%g.ppm" % dist))
        if sp:
            print("       d %-5g %d DAGs, %6d clusters %8d tris, %d occluded" % (dist, sp[0], sp[1], sp[2], sp[4]))
        ok = r.returncode in (0, 2) and len(sp) >= 5 and all(x == x and abs(x) != float("inf") for x in sp)
        check(ok and 1 <= sp[0] <= 4 and sp[1] > 0 and sp[2] > 0, "at %g m: drawn through 1 to 4 DAGs, a cut of clusters and triangles" % dist)


def images(b):
    import numpy as np
    from numpy.lib.stride_tricks import sliding_window_view as win
    for dist in (24.0, 6.0, 2.0):
        v = os.path.join(T, "v.bee")
        set_view(b, v, 0.6, 0.4, dist)
        p1, p2 = os.path.join(T, "cut.ppm"), os.path.join(T, "full.ppm")
        port("file.open " + v, "--key esc", "--move 615,360", "--wait 50", shot=p1)
        port("file.open " + v, "vgeo.view off", "--key esc", "--move 615,360", "--wait 50", shot=p2)
        i1, i2 = ppm(p1), ppm(p2)
        vr = (slice(70, 560), slice(420, 1020))  # (the viewport: no console, no toasts)
        c, f = i1[vr].astype(int), i2[vr].astype(int)
        lit = lambda x: (x.sum(axis=2) > 330)  # (the meshes over the dark backdrop)
        mc, mf = lit(c), lit(f)
        # silhouette: a pixel in one and not within 1 pixel of the other
        near = lambda x: win(np.pad(x, 1), (3, 3)).any(axis=(2, 3))
        off = ((mc & ~near(mf)) | (mf & ~near(mc))).sum()
        diff = np.abs(c - f).sum(axis=2)
        print("       d %-5g %6d pixels of mesh, %5d (%.2f%%) differ by > 24/765, %d out of silhouette by > 1 px" % (dist, mf.sum(), (diff > 24).sum(), 100 * (diff > 24).sum() / max(mf.sum(), 1), off))
        check(off <= max(30, mf.sum() // 2000), "at %g m: the silhouette holds to a pixel of error (+ a pixel of rounding)" % dist)
        if SHOTS:
            shutil.copy(p1, os.path.join(SHOTS, "cut_%g.ppm" % dist))
            shutil.copy(p2, os.path.join(SHOTS, "full_%g.ppm" % dist))


def cracks(b):
    n = 0
    bad = 0
    for k, (dist, err) in enumerate([(120, 1), (120, 4), (120, 0.25), (90, 16), (40, 1), (40, 4)]):
        v = os.path.join(T, "v.bee")
        set_view(b, v, 0.3 + k, 0.5, dist)
        r, log = port("file.open " + v, "--click-label row:T", "vgeo.error %g" % err, "vgeo.view check", "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats", size="1400x1600")
        s = [l for l in log if l.startswith("vgstat")]
        v16 = float(s[-1].split()[17]) if s else -9
        n += 1
        bad += 0 if v16 == 1 else 1
    check(bad == 0, "%d cuts as drawn (the waiting clusters with them) have level 0's edges" % n)


def stale(b):
    r, log = port("file.open " + b, "--click-label row:T", "object.modifier_add subsurf", "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats", "vgeo.view info")
    s = [l for l in log if l.startswith("vgstat")][-1].split()
    check(float(s[1]) == 3, "a stack on T: three objects left, T as its mesh (%s)" % s[1])
    check("vgeo none" in log, "  and no DAG for what it shows")


def modified():
    sv = os.path.join(T, "m.bee")
    r, log = port("add sphere", "object.modifier_add subsurf", 'object.modifier_set "0 levels 4"', "vgeo.build", "vgeo.view info", "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats", "file.save " + sv)
    s = [l for l in log if l.startswith("vgstat")][-1].split()
    check(float(s[1]) == 1 and len(infos(log)) == 1 and float(s[7]) > 200000, "an object's modifiers: its evaluated mesh is what is built and drawn (%s source triangles)" % s[7])
    i = infos(log)[0].split()
    check(i[12] == "1", "  crack-free")
    # a changed stack: the DAG no longer matches, the changed mesh shows
    r, log = port("add sphere", "object.modifier_add subsurf", 'object.modifier_set "0 levels 3"', "vgeo.build", 'object.modifier_set "0 levels 2"', "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats")
    s = [l for l in log if l.startswith("vgstat")][-1].split()
    check(float(s[1]) == 0, "the stack changed: not through the old DAG")
    # the file: it comes back with the stack
    r, log = port("file.open " + sv, "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats")
    s = [l for l in log if l.startswith("vgstat")][-1].split()
    check(float(s[1]) == 1, "saved and opened: drawn through it, no rebuild")
    out = script('op("file.open", "%s")\nprint(count(), vgeo("Sphere", 0), efaces("Sphere"))' % sv)
    check(bool(out) and out[-1].split()[1] == "2" and float(out[-1].split()[2]) > 10000, "a script opens that file: the DAG ready (as drawn), the evaluated mesh (%s)" % out[-1:])


def extract_proxy():
    p = os.path.join(T, "pr.bee")
    r, log = port("add sphere", "object.modifier_add subsurf", 'object.modifier_set "0 levels 3"', "object.modifier_apply", "vgeo.build", "vgeo.extract 2", "--click-label row:Sphere", "vgeo.extract 0.01", "--click-label row:Sphere", "vgeo.extract", "--key esc", "--wait 50")
    lod = [int(l.split()[1]) for l in log if l.startswith("LOD: ")]
    check(len(lod) == 3 and lod[1] != lod[0], "vgeo.extract: a level, an error, the middle: %s triangles" % lod)
    r, log = port("add sphere", "object.modifier_add subsurf", 'object.modifier_set "0 levels 3"', "object.modifier_apply", "vgeo.build", "vgeo.proxy", "--key esc", "--move 615,360", "--wait 50", "vgeo.view stats", "file.save " + p)
    s = [l for l in log if l.startswith("vgstat")][-1].split()
    px = [l for l in log if l.startswith("Proxy:")]
    check(len(px) == 1 and float(s[1]) >= 1, "vgeo.proxy: %s, and drawn through the DAG" % px)
    out = script('op("file.open", "%s")\nprint(vgeo("Sphere", 0), vgeo("Sphere", 12), faces("Sphere"))' % p)
    w = out[-1].split() if out else []
    check(len(w) == 3 and w[0] == "2" and w[1] == "1" and int(w[2]) < 200, "a script opens it: the proxy with its DAG, ready and crack-free (%s)" % out[-1:])


def background(src):
    r, log = port("file.open " + src, "--click-label row:T", "vgeo.build async", "--move 600,300", extra=("--dump-ui", os.path.join(T, "u.txt")))
    ui = open(os.path.join(T, "u.txt")).read()
    # (the build's chip among the others, such as the AI permission chip)
    chip = [l for l in ui.splitlines() if l.startswith("chip") and "Virtualizing" in l]
    # (a short build can be over: then the toast says so)
    check(chip and "Virtualizing the mesh" in chip[0] or any(l.startswith("Virtualized") for l in log), "a chip in the status bar while it runs: %s" % (chip[:1] or "done first"))
    r, log = port("file.open " + src, "--click-label row:T", "vgeo.build async", "vgeo.build async", "vgeo.view wait", "vgeo.view info")
    check(any("being virtualized already" in l for l in log) or sum(1 for l in log if l.startswith("Virtualized")) == 2, "one build at a time")
    check(any(l.startswith("Virtualized") for l in log) and len(infos(log)) == 1, "it lands in the scene")


def streaming(b):
    v = os.path.join(T, "v.bee")
    set_view(b, v, 0.5, 0.4, 4)
    r, log = port("file.open " + v, "--key esc", "--move 615,360", "--wait 400", "--move 620,360", "--wait 400", "vgeo.view stats")
    s = [float(x) for x in [l for l in log if l.startswith("vgstat")][-1].split()[1:]]
    check(s[14] >= 1 and s[10] > 0, "a DAG from a file stays mapped (%d streamed), pages come in (%d read, %.1f MB in memory)" % (s[14], s[10], s[7]))
    set_view(b, v, 0.5, 0.2, 1.2)
    orbit = sum([["--drag 600,300,%d,%d" % (600 + 90 * ((k % 5) - 2), 300 + 40 * (k % 3)), "--bench 6"] for k in range(12)], [])
    r, log = port("file.open " + v, "--click-label row:T", "vgeo.error 0.05", "vgeo.view check", "--key esc", "--move 615,360", "--bench 6", *orbit, "vgeo.budget 2", "--key esc", "--move 615,360", *orbit, "vgeo.view stats", size="1400x1600")
    s = [float(x) for x in [l for l in log if l.startswith("vgstat")][-1].split()[1:]]
    check(s[11] > 0 and s[7] <= 2.1 and s[8] == 2 and s[16] != 0, "a budget of 2 MB holds while the view flies: %.2f MB, %d pages read, %d given back" % (s[7], s[10], s[11]))
    r, log = port("file.open " + v, "--key esc", "--move 615,360", "--wait 300", "file.save " + v, "file.open " + v, "--wait 300", "vgeo.view stats")
    check(any(l.startswith("vgstat") for l in log), "saving over the file a DAG is mapped from")


def damage(b):
    d0 = open(b, "rb").read()
    V = vgeos(b)
    spans = sorted((o, len(bl)) for _, o, bl in V.values())
    rng = random.Random(SEED)
    bad = 0
    cl = 0
    for k in range(RUNS):
        d = bytearray(d0)
        o, n = rng.choice(spans)
        hd = head(d[o : o + VH])
        for _ in range(rng.choice([1, 1, 4, 32])):
            kind = rng.randrange(4)
            if kind == 0:
                at = o + rng.randrange(VH)  # the header
            elif kind == 1:
                at = o + VH + rng.randrange(max(hd["ncl"] * 64, 64))  # the clusters
            elif kind == 2:
                at = o + rng.randrange(n)
            else:
                at = o + n - rng.randrange(1, min(n, 1 << 16))  # the data
            v = rng.choice([0, 0xff, 0x7f, 0x80, rng.randrange(256)])
            if rng.random() < 0.3:
                at &= ~3
                struct.pack_into("<I", d, at, rng.choice([0, 0xffffffff, 0x7fffffff, 0x7fc00000, 0x7f800000, 1 << 31, rng.randrange(1 << 32)]))
            else:
                d[at] = v
        p = os.path.join(T, "d.bee")
        open(p, "wb").write(d)
        r, log = port("file.open " + p, "--key esc", "--move 615,360", "--wait 20", "--wheel 615,360,-8", "--wait 20", "view.shading_wireframe" if k % 3 == 0 else "view.toggle_material_preview" if k % 3 == 1 else "vgeo.view clusters", "--key esc", "--wait 20", "file.save /tmp/%s-d2.bee" % os.path.basename(T))
        if r.returncode not in (0, 2):
            bad += 1
            shutil.copy(p, "/tmp/vgeo-crash-%d.bee" % k)
            print("  crash rc", r.returncode, r.stderr[-1500:])
        if any("damaged" in l or "lossy" in l or "not" in l for l in log):
            cl += 1
    # a chunk that says it is huge
    d = bytearray(d0)
    o, n = spans[0]
    struct.pack_into("<Q", d, o + 112, 1 << 46)
    p = os.path.join(T, "d.bee")
    open(p, "wb").write(d)
    t0 = time.time()
    r, log = port("file.open " + p, "--key esc", "--wait 20")
    if r.returncode not in (0, 2) or time.time() - t0 > 30:
        bad += 1
    check(bad == 0, "no crash, no huge allocation in %d damaged files" % (RUNS + 1))
    try:
        os.unlink("/tmp/%s-d2.bee" % os.path.basename(T))
    except OSError:
        pass


main()
print("fails %d" % fails)
sys.exit(1 if fails else 0)
