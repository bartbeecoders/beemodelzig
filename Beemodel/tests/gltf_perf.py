#!/usr/bin/env python3
"""glTF import and export speed, a release build, one CPU (BEE_CPU, default
22): a large scene (a million triangles in many nodes and meshes) imported,
and the scene exported as .glb and .gltf. The times are printed (best of
runs, start-up taken off); the import must end within PERF_LIMIT seconds
(default 60) and give every node, the saved .bee read back whole; each export
must import again with every object, and the .bee saved, opened and saved
again must be the same.

    python3 tests/gltf_perf.py BIN [runs=3]

Big files go under GLTF_PERF_DIR (default: .gltf-scratch in the project), the
exports under GLTF_PERF_OUT (default the same; the atomic write fsyncs:
/dev/shm shows the export without the disk).
"""
import os, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
import gltf_gen

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 3
CPU = os.environ.get('BEE_CPU', '22')
LIMIT = float(os.environ.get('PERF_LIMIT', '60'))
BASE = os.environ.get('GLTF_PERF_DIR', os.path.join(ROOT, '.gltf-scratch'))
os.makedirs(BASE, exist_ok=True)
T = tempfile.mkdtemp(prefix='perf-', dir=BASE)
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def big_file(path, nodes=400, grid=36):
    """nodes x a grid mesh of 2 x grid^2 x ... triangles: about 1M triangles,
    each node its own mesh (positions, u32 indices, float UVs), a material each tenth"""
    g = gltf_gen.G()
    n = grid
    tris = []
    for j in range(n):
        for i in range(n):
            a = j * (n + 1) + i
            tris += [a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2]
    idx = struct.pack('<%dI' % len(tris), *tris)
    uv = b''.join(struct.pack('<2f', i / n, j / n) for j in range(n + 1) for i in range(n + 1))
    for k in range(nodes):
        pts = b''.join(struct.pack('<3f', i * 0.1, ((i * 7 + j * 3 + k) % 11) * 0.01, j * 0.1) for j in range(n + 1) for i in range(n + 1))
        pa = g.acc(g.view(pts), 5126, (n + 1) ** 2, 'VEC3')
        ua = g.acc(g.view(uv), 5126, (n + 1) ** 2, 'VEC2')
        ia = g.acc(g.view(idx), 5125, len(tris), 'SCALAR')
        prim = {'attributes': {'POSITION': pa, 'TEXCOORD_0': ua}, 'indices': ia}
        if k % 10 == 0:
            prim['material'] = g.material({'name': 'M%d' % k, 'pbrMetallicRoughness': {'baseColorFactor': [k / nodes, 0.5, 0.2, 1]}})
        g.mesh([prim], 'G%d' % k)
        g.node(root=k % 20 == 0, mesh=k, name='N%d' % k, translation=[4.0, 0, 0] if k % 20 else [0, 0, (k // 20) * 4.0])
        if k % 20:   # (chains of 20 under 20 roots: the walk's stack holds 32)
            g.d['nodes'][k - 1]['children'] = [k]
    g.write(path, 'glb')
    return nodes * n * n * 2


def run(b, code, timeout=1800):
    t0 = time.time()
    r = subprocess.run(['taskset', '-c', CPU, b, '--eval', code], capture_output=True, text=True, timeout=timeout, cwd=T,
                       env=dict(os.environ, BEEMODEL_GPU='off'))
    return time.time() - t0, r.returncode


def best(b, code):
    ts = []
    for _ in range(RUNS):
        dt, rc = run(b, code)
        if rc != 0:
            return None
        ts.append(dt)
    return min(ts)


def main():
    src = os.path.join(T, 'big.glb')
    ntri = big_file(src)
    print('-- %d triangles, %d MB, %d runs each, CPU %s --' % (ntri, os.path.getsize(src) >> 20, RUNS, CPU), flush=True)
    clear = 'n = count()\nfor i in 0..n { delete(name(0)) }\n'
    base = best(BIN, clear)
    imp = clear + 'op("file.import_gltf", "%s")' % src
    t_p = best(BIN, imp)
    ok = None not in (t_p, base)
    ip = (t_p - base) if ok else 0
    check(ok and ip <= LIMIT, 'import: %.2f s (start-up %.2f s taken off: %.2f s)' % (t_p or 0, base or 0, ip))
    # the result: every node, the .bee read back whole, saved again the same
    bp, bp2 = os.path.join(T, 'p.bee'), os.path.join(T, 'p2.bee')
    run(BIN, imp + '\nop("file.save", "%s")' % bp)
    run(BIN, 'op("file.open", "%s")\nop("file.save", "%s")' % (bp, bp2))
    nobj = len(beefile.objects(bp)) if os.path.exists(bp) else 0
    ntris = 0
    if nobj:
        ms = beefile.meshes(bp)
        ntris = sum(len(pl) - 2 for vs, ps in ms for pl in ps)
    same = os.path.exists(bp2) and [c for c in beefile.chunks(bp) if c[0] != b'WSPC'] == [c for c in beefile.chunks(bp2) if c[0] != b'WSPC']
    check(nobj == 400 and ntris >= ntri and same, 'the imported scene saved: %d objects, %d triangles; opened and saved again the same' % (nobj, ntris))
    # the export (of the imported scene, from the .bee)
    for ext in ('glb', 'gltf'):
        od = os.environ.get('GLTF_PERF_OUT', T)   # (where the exports go: they are fsynced)
        gp = os.path.join(od, 'p.' + ext)
        opn = 'op("file.open", "%s")\n' % bp
        b0 = best(BIN, opn)
        e_p = best(BIN, opn + 'op("file.export_gltf", "%s")' % gp)
        ok = None not in (e_p, b0)
        ep = (e_p - b0) if ok else 0
        check(ok and ep <= LIMIT, 'export .%s: %.2f s (opening the .bee taken off: %.2f s)' % (ext, ep, b0 or 0))
        back = os.path.join(T, 'back.bee')
        run(BIN, clear + 'op("file.import_gltf", "%s")\nop("file.save", "%s")' % (gp, back))
        nb = len(beefile.objects(back)) if os.path.exists(back) else 0
        check(nb == 400, 'the .%s (%d MB) imported again: %d objects' % (ext, (os.path.getsize(gp) if os.path.exists(gp) else 0) >> 20, nb))
        for f in (gp, back):
            if os.path.exists(f):
                os.remove(f)
    shutil.rmtree(T, True)
    print('fails %d' % len(FAILS))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
