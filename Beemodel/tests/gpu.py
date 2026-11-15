#!/usr/bin/env python3
"""The optional GPU helper (beemodel-gpu): the CPU stays the reference, the GPU's images must match it within noise, and every
way the helper can be missing or fail must end in the CPU's image.

  * Static: the main binary links nothing; the helper starts next to it.
  * Fallbacks: helper missing, BEEMODEL_GPU=off, Device CPU, a graph node the GPU
    lacks; the app behaves as without it.
  * Render against the CPU at 64 samples (RTX and compute): default, glass /
    metal / coat / emission / point light, textures + shader graphs, HDRI. Same
    streams, so the distance must be far below the noise between two seeds.
  * The helper dying (BEEMODEL_GPU_FAIL=2), killed from outside mid-render, hung
    (BEEMODEL_GPU_HANG=2): the render ends on the CPU with the CPU's image, on
    time, no process left.
  * The slot is untrusted: bad tables, sizes and messages end in a refusal, never
    a crash (the helper driven directly over its socket).
  * Rendered shading: raycast, samples, denoise, motion samples, the scene going up
    again, Material Preview / CPU after the helper dies, F12 beside it.

With no usable Vulkan device the GPU checks are skipped (exit 0, says so).
    python3 tests/gpu.py [bin/beemodel] [--require] [--untrusted]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import mmap, os, re, shutil, signal, socket, struct, subprocess, sys, tempfile, time

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
REQUIRE = '--require' in sys.argv
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.abspath(ARGS[0] if ARGS else os.path.join(ROOT, 'zig-out-debug', 'bin', 'beemodel'))
HELPER = os.environ.get('BEEMODEL_GPU_HELPER', os.path.join(os.path.dirname(BIN), 'beemodel-gpu'))
TMP = tempfile.mkdtemp(prefix='bee-gpu-', dir='/tmp/beemodel-headless' if os.path.isdir('/tmp/beemodel-headless') else None)
FAILS = []
DEVICE = ''
helper_hello = bytes(64)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def env(**kw):
    e = dict(os.environ)
    for k in ('BEEMODEL_GPU', 'BEEMODEL_GPU_HELPER', 'BEEMODEL_GPU_FAIL', 'BEEMODEL_GPU_HANG', 'BEEMODEL_GPU_RTX', 'BEEMODEL_GPU_TIMEOUT_MS',
              'BEEMODEL_GPU_VIEW', 'BEEMODEL_GPU_RASTER', 'BEEMODEL_GPU_HOSTMEM'):
        e.pop(k, None)
    if 'BEEMODEL_GPU_HELPER' in os.environ:
        e['BEEMODEL_GPU_HELPER'] = HELPER
    e.update(kw)
    return e


def cmds(*c):
    a = []
    for x in c:
        a += ['--key', 'enter', '--type', x, '--key', 'enter', '--key', 'esc']
    return a


def shot(tag, args, timeout=300, **kw):
    out, log, ui = [os.path.join(TMP, tag + x) for x in ('.ppm', '.log', '.ui')]
    r = subprocess.run([BIN, '--shot', out, '--dump-ui', ui] + args + ['--dump-log', log], env=env(**kw), cwd=ROOT,
                       capture_output=True, text=True, timeout=timeout)
    logt = open(log).read() if os.path.exists(log) else ''
    uit = open(ui).read() if os.path.exists(ui) else ''
    return r.returncode, logt, uit, out


def render(tag, pre, spp=64, size=(240, 180), **kw):
    png = os.path.join(TMP, tag + '.png')
    a = cmds(*pre, 'render.settings %d %d %d' % (size[0], size[1], spp), 'render.denoise')
    a += ['--move', '615,360', '--key', 'f12', '--render-wait'] + cmds('render.save ' + png, 'render.device')
    rc, log, _, _ = shot(tag, a, **kw)
    return rc, log, png


def pixels(path):
    from PIL import Image
    return Image.open(path).convert('RGB')


def compare(a, b, box=None):
    """(mean absolute difference in levels, share of identical pixels, worst)"""
    import numpy as np
    x, y = pixels(a), pixels(b)
    if box:
        x, y = x.crop(box), y.crop(box)
    x, y = np.asarray(x).astype(float), np.asarray(y).astype(float)
    if x.shape != y.shape:
        return 255.0, 0.0, 255
    d = abs(x - y)
    return float(d.mean()), float((d.max(axis=2) == 0).mean()), float(d.max())


def where(log):
    m = re.search(r'rendering .*?, on the (GPU \(RTX\)|GPU|CPU)', log)
    return m.group(1) if m else '?'


def nopids():
    r = subprocess.run(['pgrep', '-P', str(os.getpid())], capture_output=True, text=True)
    return r.stdout.strip() == ''


HDRI = ['image.load tests/files/gpu_world.hdr', 'world.hdri gpu_world']
SCENES = [('default', [], 0.02), ('glass', ['file.open tests/files/gpu_glass.bee'], 0.08),
          ('graph', ['file.open tests/files/gpu_graph.bee'], 0.05), ('textured', ['file.open tests/files/tex_uv.bee'], 0.05),
          ('box uv', ['file.open tests/files/gpu_subsurf.bee'], 0.05),     # (a subsurf: UVs negative, GLSL's % undefined)
          ('hdri', HDRI, 0.02), ('hdri glass', ['file.open tests/files/gpu_glass.bee'] + HDRI, 0.08)]


def renders(rtx):
    print('  -- renders against the CPU (64 samples, 240 x 180) --')
    cpu = {}
    for name, pre, lim in SCENES:
        tag = name.replace(' ', '_')
        rc, log, ref = render(tag + '_cpu', pre, BEEMODEL_GPU='off')
        cpu[name] = ref
        check(rc == 0 and where(log).startswith('CPU'), f'{name}: on the CPU with BEEMODEL_GPU=off')
        modes = [('compute', {'BEEMODEL_GPU_RTX': 'off'}, 'GPU')]
        if rtx:
            modes.insert(0, ('rtx', {}, 'GPU (RTX)'))
        for mode, e, want in modes:
            rc, log, png = render(tag + '_' + mode, pre, **e)
            mae, same, worst = compare(ref, png)
            print(f'       {name:10} {mode:8} {mae:.4f} levels, {same * 100:.2f}% identical, worst {worst:.0f}')
            check(rc == 0 and where(log) == want and mae < lim, f'{name}: {mode} within {lim} levels of the CPU, on the {where(log)}')
    # what "noise" means: the same scene, another seed (a second render, its own streams)
    a = os.path.join(TMP, 'seed.png')
    b = os.path.join(TMP, 'seed2.png')
    arg = cmds('file.open tests/files/gpu_glass.bee', 'render.settings 240 180 64', 'render.denoise')
    arg += ['--move', '615,360', '--key', 'f12', '--render-wait'] + cmds('render.save ' + a)
    arg += ['--move', '615,360', '--key', 'f12', '--render-wait'] + cmds('render.save ' + b)
    shot('seed', arg, BEEMODEL_GPU='off')
    noise = compare(a, b)[0]
    gm = compare(cpu['glass'], os.path.join(TMP, 'glass_compute.png'))[0]
    print(f'       glass: two CPU seeds differ by {noise:.2f} levels; the GPU differs from the CPU by {gm:.4f}')
    check(noise > 20 * gm, 'the GPU is far nearer the CPU than the noise between two seeds')
    return cpu


def fallbacks(cpu_png):
    print('  -- fallbacks --')
    missing = os.path.join(TMP, 'nothing-here')
    rc, log, png = render('nohelper', [], BEEMODEL_GPU_HELPER=missing)
    check(rc == 0 and where(log).startswith('CPU') and compare(cpu_png, png)[1] == 1.0, 'helper missing: the CPU, the same image')
    check('GPU helper: not used' in log, 'helper missing: the console says so')
    rc, log, _ = render('notexe', [], BEEMODEL_GPU_HELPER='/etc/passwd')
    check(rc == 0 and where(log).startswith('CPU'), 'a helper that cannot run: the CPU')
    rc, log, png = render('devcpu', ['render.device cpu'])
    check(rc == 0 and 'Device is CPU' in log and compare(cpu_png, png)[1] == 1.0, 'render.device cpu: the CPU, it says why')
    rc, log, _ = render('brick', ['file.open tests/files/gpu_brick.bee'])
    check(rc == 0 and 'a material node the GPU lacks' in log, 'a node the GPU lacks: the CPU, it says why')


def failures(cpu_png, rtx, glass_png):
    print('  -- the helper failing --')
    rc, log, png = render('die', [], BEEMODEL_GPU_FAIL='2', spp=64)
    mae = compare(cpu_png, png)[0]
    check(rc == 0 and 'the GPU failed' in log and mae < 0.02, f'dying at its second run: the rest on the CPU, {mae:.4f} levels from the CPU alone')
    # hung: a run that never answers; the render still ends on the CPU
    t = time.time()
    rc, log, png = render('hang', [], BEEMODEL_GPU_HANG='2', BEEMODEL_GPU_TIMEOUT_MS='1500', spp=64)
    took = time.time() - t
    check(rc == 0 and 'no answer in time' in log and took < 30 and compare(cpu_png, png)[0] < 0.02,
          f'hung: killed after its timeout, ended on the CPU ({took:.1f} s)')
    # killed from outside in the middle of a render (each run made slow, so that the
    # kill lands in it: a real render here ends in a fraction of a second)
    png = os.path.join(TMP, 'kill.png')
    a = cmds('file.open tests/files/gpu_glass.bee', 'render.settings 240 180 64', 'render.denoise')
    a += ['--move', '615,360', '--key', 'f12', '--render-wait'] + cmds('render.save ' + png)
    p = subprocess.Popen([BIN, '--shot', os.path.join(TMP, 'kill.ppm')] + a + ['--dump-log', os.path.join(TMP, 'kill.log')],
                         env=env(BEEMODEL_GPU_SLOW='100'), cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    killed = False
    t0 = time.time()
    while time.time() - t0 < 5 and not killed:
        r = subprocess.run(['pgrep', '-P', str(p.pid)], capture_output=True, text=True)
        if r.stdout.strip():
            time.sleep(1.0)
            os.kill(int(r.stdout.split()[0]), signal.SIGKILL)
            killed = True
        time.sleep(0.01)
    rc = p.wait(timeout=120)
    log = open(os.path.join(TMP, 'kill.log')).read()
    m = re.search(r'(\d+) samples kept', log)
    mae = compare(glass_png, png)[0] if os.path.exists(png) else 255
    check(killed and rc == 0 and m and 0 < int(m.group(1)) < 64 and 'render finished: 64 samples' in log and mae < 0.08,
          f'killed mid-render: {m.group(1) if m else "no"} GPU samples kept, the rest on the CPU, {mae:.4f} levels from the CPU alone')
    check(nopids(), 'no process left behind')


def msg(cmd, slot=0, a=0, b=0, c=0, d=0):
    return struct.pack('<6I', cmd, slot, a, b, c, d) + bytes(40)


def helper():
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    def child():
        os.dup2(b.fileno(), 3)
        os.set_inheritable(3, True)
    p = subprocess.Popen([HELPER], preexec_fn=child, close_fds=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env())
    b.close()
    a.settimeout(20)
    return p, a, a.recv(64)


def ended(p):
    """Its exit, not a crash."""
    try:
        return p.wait(timeout=20) >= 0
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        return False


def untrusted():
    print('  -- the slot is untrusted --')
    SIZE = 1 << 20
    def mapped(slot=0):
        p, s, hello = helper()
        fd = os.memfd_create('t')
        os.ftruncate(fd, SIZE)
        s.sendmsg([msg(2, slot, SIZE, 0)], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack('i', fd))])
        status = struct.unpack('<II', s.recv(64)[:8])[1]
        return p, s, fd, status
    def table(fd, rows):
        m = mmap.mmap(fd, SIZE)
        for i, (off, n, flags) in enumerate(rows):
            m[i * 32:i * 32 + 32] = struct.pack('<QQIIII', off, n, flags, 0, 0, 0)
        return m
    good = [(4096, 2048, 1)] + [(4096 + i * 4096, 2048, 0) for i in range(1, 20)]
    valid = struct.pack('<12I', 1, 1, 0, 1, 7, 2, 0, 0, 0, 0, 0, 0) + bytes(16 * 4)     # one pixel, no triangles
    def runit(rows, nbind=20, gx=1, gy=1, kern=1, params=valid, ranges=None, slot=0, ndraw=0):
        p, s, fd, st = mapped(slot)
        m = table(fd, rows)
        m[4096:4096 + len(params)] = params
        for i, r in enumerate(ranges or []):
            m[1024 + i * 16:1040 + i * 16] = struct.pack('<QQ', *r)
        if ranges:
            m[32 + 24:32 + 32] = struct.pack('<II', ranges and 0, len(ranges))
        s.send(struct.pack('<7I', 3, slot, nbind, gx, gy, kern, ndraw) + bytes(36))
        try:
            r = s.recv(64)
        except OSError:
            r = b''
        code = struct.unpack('<II', r[:8])[1] if len(r) == 64 else -1
        return p, s, st, code
    # the control: all the refusals below differ from this in one thing
    p, s, st, code = runit(good)
    check(st == 0 and code == 0, 'a good table runs (the refusals below would be empty otherwise)')
    s.close()
    check(ended(p), 'it ends when the socket closes')
    delta = list(good)
    delta[1] = (8192, 2048, 1 | 4)
    p, s, st, code = runit(delta, ranges=[(8192, 2048)])
    check(st == 0 and code == 0, 'a good range runs')
    s.close()
    ended(p)
    def refused(name, rows, **kw):
        p, s, st, code = runit(rows, **kw)
        check(st == 0 and code != 0 and ended(p), f'{name}: refused, no crash')
    refused('a binding past the slot', [(4096, SIZE, 1)] + good[1:])
    refused('a misaligned binding', good[:1] + [(8193, 16, 0)] + good[2:])
    refused('an offset that wraps', good[:1] + [(2 ** 64 - 256, 512, 0)] + good[2:])
    refused('a binding over the table', good[:1] + [(0, 512, 0)] + good[2:])
    refused('an empty binding', good[:1] + [(8192, 0, 0)] + good[2:])
    refused('the wrong table size', good, nbind=5)
    refused('a table past the limit', good, nbind=1 << 30)
    refused('an unknown kernel', good, kern=3 + 4)
    refused('an RTX kernel on the compute table', good, kern=4)
    refused('an image larger than its accumulators', good, params=struct.pack('<4I', 2000, 2000, 0, 1) + valid[16:])
    refused('a width of none', good, params=bytes(len(valid)))
    refused('more triangles than bindings hold', good, params=valid[:32] + struct.pack('<I', 1 << 20) + valid[36:])
    refused('workgroups past the limit', good, gx=1 << 20)
    refused('ranges past the list', delta[:1] + [(8192, 2048, 1 | 4 | 0)] + delta[2:], ranges=[(8192, 16)] * 1 + [(0, 0)] * 200)
    refused('a range outside its binding', delta, ranges=[(8192, 8192)])
    refused('a range before its binding', delta, ranges=[(4096, 16)])
    refused('an empty range', delta, ranges=[(8192, 0)])
    # the tile stage and the viewport: a good run, then one thing wrong
    rgood = [(4096 + i * 4096, 2048, 1 if i == 0 else 0) for i in range(8)]
    rp = struct.pack('<8I', 16, 16, 1, 0, 0, 0, 0, 0)
    p, s, st, code = runit(rgood, nbind=8, kern=2, params=rp, slot=1)
    check(code == 0, 'the tile stage: a good table runs')
    s.close()
    ended(p)
    refused('tiles that do not match the width', rgood, nbind=8, kern=2, params=struct.pack('<8I', 16, 16, 9, 0, 0, 0, 0, 0), slot=1)
    refused('more workgroups than tiles', rgood, nbind=8, kern=2, params=rp, slot=1, gx=9)
    refused('a depth smaller than the region', rgood, nbind=8, kern=2, params=struct.pack('<8I', 1600, 16, 100, 0, 0, 0, 0, 0), slot=1, gx=100)
    refused('the tile stage in another slot', rgood, nbind=8, kern=2, params=rp, slot=0)
    if struct.unpack('<I', helper_hello[12:16])[0] & 0x200:
        vgood = [(4096 + i * 4096, 2048, 0) for i in range(16)]
        p, s, st, code = runit(vgood, nbind=16, kern=7, params=b'', slot=3, gx=16, gy=16)
        check(code == 0, 'the viewport: a good table runs')
        s.close()
        ended(p)
        refused('more draws than commands', vgood, nbind=16, kern=7, params=b'', slot=3, gx=16, gy=16, ndraw=1 << 20)
        refused('an image larger than its bindings', vgood, nbind=16, kern=7, params=b'', slot=3, gx=1000, gy=1000)
        refused('an image of no size', vgood, nbind=16, kern=7, params=b'', slot=3, gx=0, gy=16)
        refused('the viewport in another slot', vgood, nbind=16, kern=7, params=b'', slot=2, gx=16, gy=16)
    # a map larger than the memory behind it, none at all, a bad slot
    p, s, hello = helper()
    fd = os.memfd_create('t')
    os.ftruncate(fd, 4096)
    s.sendmsg([msg(2, 0, 1 << 30, 0)], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack('i', fd))])
    r = s.recv(64)
    check(struct.unpack('<II', r[:8])[1] != 0 and ended(p), 'a map larger than its memfd: refused, no crash')
    p, s, hello = helper()
    s.send(msg(2, 0, SIZE, 0))
    r = s.recv(64)
    check(struct.unpack('<II', r[:8])[1] != 0 and ended(p), 'a map without a memfd: refused, no crash')
    p, s, hello = helper()
    s.send(msg(3, 77, 20, 1, 1, 1))
    r = s.recv(64)
    check(struct.unpack('<II', r[:8])[1] != 0 and ended(p), 'a bad slot: refused, no crash')
    p, s, hello = helper()
    s.send(b'x' * 7)
    check(ended(p), 'a short message: it ends, no crash')
    p, s, hello = helper()
    s.close()
    check(ended(p), 'the socket closing: it ends')


def viewport():
    print('  -- the viewport on the GPU, against the CPU\'s --')
    glass = 'file.open tests/files/gpu_glass.bee'
    graph = 'file.open tests/files/gpu_graph.bee'
    mat = 'view.shading_material'
    for name, pre, lim in (('solid', [], 0.02), ('solid glass', [glass], 0.05), ('material', [mat], 0.02), ('material glass', [glass, mat], 0.08),
                           ('material graph', [graph, mat], 0.08), ('material box uv', ['file.open tests/files/gpu_subsurf.bee', mat], 0.02),
                           ('material hdri', [glass] + HDRI + [mat], 0.08)):
        tag = 'v_' + name.replace(' ', '_')
        a = cmds(*pre) + ['--move', '5,5'] + cmds('render.device')
        rc, log, _, c = shot(tag + '_c', a, BEEMODEL_GPU_VIEW='off')
        rc2, log2, _, g = shot(tag + '_g', a, BEEMODEL_GPU_VIEW='on')
        u = re.search(r'viewport: (\d+) frames', log2)
        off = re.search(r'viewport: (\d+) frames', log)
        mae, same, worst = compare(c, g, BOX)
        print(f'       {name:16} {mae:.4f} levels, {same * 100:.2f}% identical')
        check(rc == 0 and rc2 == 0 and u and int(u.group(1)) > 0 and int(off.group(1)) == 0 and mae < lim, f'{name}: drawn by the GPU, within {lim} levels')
    # a click still picks through the ids it sends back
    a = ['--move', '5,5', '--click', '200,700', '--click', '615,400'] + cmds('render.device')
    rc, log, ui, _ = shot('v_pick', a, BEEMODEL_GPU_VIEW='on')
    rc2, log2, ui2, _ = shot('v_pick2', a, BEEMODEL_GPU_VIEW='off')
    check(rc == 0 and [l for l in ui.splitlines() if l.startswith('row')] == [l for l in ui2.splitlines() if l.startswith('row')], 'a click picks the same object')
    # edit mode, the CPU's: the view moves, no frame goes to the GPU
    a = ['--move', '615,360', '--key', 'tab'] + cmds('render.device') + ['--mdrag', '500,300,560,320', '--wait', '50'] + cmds('render.device')
    rc, log, _, _ = shot('v_edit', a, BEEMODEL_GPU_VIEW='on')
    u = re.findall(r'viewport: (\d+) frames', log)
    a = ['--move', '615,360'] + cmds('render.device') + ['--mdrag', '500,300,560,320', '--wait', '50'] + cmds('render.device')
    rc2, log2, _, _ = shot('v_noedit', a, BEEMODEL_GPU_VIEW='on')
    u2 = re.findall(r'viewport: (\d+) frames', log2)
    check(rc == 0 and u[0] == u[-1] and int(u2[-1]) > int(u2[0]), f'edit mode draws on the CPU ({u[0]} -> {u[-1]} GPU frames; object mode {u2[0]} -> {u2[-1]})')
    print('  -- the tile stage on the GPU --')
    dag = ['add sphere', 'object.modifier_add subsurf', 'object.modifier_set "0 levels 3"', 'vgeo.build']
    for name, pre, e in (('every mesh', [], {'BEEMODEL_GPU_RASTER': 'all'}), ('cluster DAG', dag, {'BEEMODEL_GPU_RASTER': 'all'}), ('DAG by default', ['render.device'] + dag, {})):
        a = cmds(*pre) + ['--move', '5,5'] + cmds('render.device')
        rc, log, _, c = shot('r_c', a, BEEMODEL_GPU_RASTER='off')
        rc2, log2, _, g = shot('r_g', a, **e)
        u = re.findall(r'raster: (\d+) batches, (\d+) on the CPU', log2)[-1]
        off = re.findall(r'raster: (\d+) batches', log)[-1]
        mae, same, worst = compare(c, g, BOX)
        check(rc == 0 and rc2 == 0 and int(u[0]) > 0 and u[1] == '0' and int(off) == 0 and same == 1.0, f'{name}: {u[0]} batches ({u[1]} on the CPU), {(1 - same) * (BOX[2] - BOX[0]) * (BOX[3] - BOX[1]):.0f} pixels differ')
    print('  -- shared memory --')
    p, s, hello = helper()
    s.close()
    p.wait(timeout=20)
    if struct.unpack('<I', hello[12:16])[0] & 0x400:
        rc, log, a = render('hm_on', ['file.open tests/files/gpu_graph.bee'])
        rc2, log2, b = render('hm_off', ['file.open tests/files/gpu_graph.bee'], BEEMODEL_GPU_HOSTMEM='off')
        check('shared memory imported' in log and 'shared memory copied' in log2 and compare(a, b)[1] == 1.0, 'imported or copied: the same image, the console says which')


def hud(ui):
    m = re.findall(r'^info\t(Rendered[^\t]*)', ui, re.M)
    return m[0] if m else ''


BOX = (220, 130, 1000, 640)                             # the viewport, away from its widgets


def live(rtx):
    print('  -- Rendered shading --')
    pre = cmds('view.rendered_samples 32', 'view.shading_rendered') + ['--move', '615,360']
    rc, log, ui, g = shot('live_gpu', pre + ['--live-wait'])
    check(rc == 0 and hud(ui) == 'Rendered  |  32 samples, denoised', f'samples on the GPU, denoised: "{hud(ui)}"')
    rc, log, ui, c = shot('live_cpu', pre + ['--live-wait'], BEEMODEL_GPU='off')
    check(rc == 0 and hud(ui) == 'Rendered  |  32 samples, denoised', 'the CPU path as before')
    mae = compare(g, c, BOX)[0]
    check(mae < 0.5, f'the GPU\'s view against the CPU\'s: {mae:.3f} levels')
    rc, log, ui, r = shot('live_ray', cmds('view.rendered_samples 0', 'view.shading_rendered') + ['--move', '615,360', '--live-wait'])
    check(rc == 0 and hud(ui) == 'Rendered  |  raycast', f'0 samples: the raycast alone ("{hud(ui)}")')
    # the view moves with a middle drag: a raycast of it, the scene not sent again
    pre2 = pre + ['--live-wait', '--mdrag', '500,300,560,320', '--live-wait']
    rc, log, ui, m = shot('live_move', pre2 + cmds('render.device'))
    u = re.search(r'Rendered: (\d+) raycasts .*?, (\d+) scene uploads', log)
    check(rc == 0 and u and int(u.group(2)) == 1 and hud(ui).startswith('Rendered  |  32'), f'a camera move: no new upload ({u.groups() if u else None})')
    rc, log, ui, m = shot('live_scene', pre + ['--live-wait', '--move', '615,360', '--key', 'g', '--key', 'x', '--type', '1', '--key', 'enter', '--live-wait'] + cmds('render.device'))
    u = re.search(r'Rendered: (\d+) raycasts .*?, (\d+) scene uploads', log)
    check(rc == 0 and u and int(u.group(2)) >= 2 and compare(g, m, BOX)[0] > 0.2, f'a scene change: it goes up again and shows ({u.groups() if u else None})')
    # motion samples on the GPU and on the CPU
    a = cmds('view.rendered_motion 2', 'view.rendered_samples 2', 'view.shading_rendered') + ['--move', '615,360', '--live-wait']
    rc, log, ui, m = shot('live_motion', a)
    check(rc == 0 and hud(ui) == 'Rendered  |  2 samples, denoised', f'motion samples: 2 a frame, denoised ("{hud(ui)}")')
    rc, log, ui, m2 = shot('live_motion_cpu', a, BEEMODEL_GPU='off')
    check(rc == 0 and hud(ui) == 'Rendered  |  2 samples, denoised', f'motion samples on the CPU ("{hud(ui)}")')
    # no denoise
    rc, log, ui, m = shot('live_nodn', cmds('view.rendered_samples 8', 'view.rendered_denoise 0', 'view.shading_rendered') + ['--move', '615,360', '--live-wait'])
    check(rc == 0 and hud(ui) == 'Rendered  |  8 samples', f'denoise off ("{hud(ui)}")')
    # F12 beside it
    a = pre + ['--live-wait'] + cmds('render.settings 320 180 16') + ['--move', '615,360', '--key', 'f12', '--render-wait', '--live-wait']
    rc, log, ui, m = shot('live_f12', a + cmds('render.device'))
    check(rc == 0 and 'render finished: 16 samples' in log and 'on the GPU' in log, 'F12 beside it')
    # the helper dies under the view: the CPU's path from there
    rc, log, ui, m = shot('live_die', pre + ['--live-wait', '--live-wait'], BEEMODEL_GPU_FAIL='3')
    check(rc == 0 and 'the CPU from here on' in log and hud(ui).startswith('Rendered'), f'the helper dying: the CPU takes the view ("{hud(ui)}")')


def window():
    """The real main loop in the fake compositor (tests/wl_fake.py): the helper
    starts as the window opens, and a hung helper freezes nothing."""
    print('  -- a window --')
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import wl_fake
    letters = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}

    def start(**kw):
        e = env(**kw)
        e.pop('WAYLAND_DISPLAY', None)
        f = wl_fake.Fake(BIN, size=(1280, 800), env={k: v for k, v in e.items() if k.startswith('BEEMODEL_')})
        f.until(lambda: f.frames > 0, 10)
        f.pump(1.0)
        f.enter(640, 400)
        f.pump(0.2)
        return f

    def cmd(f, t):
        f.key(28)
        f.pump(0.1)
        for c in t:
            if c == '_':
                f.key(12, 1)             # shift + minus
            else:
                f.key(52 if c == '.' else 57 if c == ' ' else letters[c])
        f.pump(0.1)
        f.key(28)
        f.pump(0.2)
        f.key(1)
        f.pump(0.2)

    def move(f, x, y):
        f.motion(x, y)

    def children(f):
        return subprocess.run(['pgrep', '-P', str(f.proc.pid)], capture_output=True, text=True).stdout.split()

    def worst_frame(f, n=30):
        """The longest a pointer move waits for a frame (ms)."""
        worst = 0
        for i in range(n):
            before = f.frames
            t = time.time()
            move(f, 420 + i * 7 % 300, 300 + i)
            while f.frames == before and time.time() - t < 5:
                f.pump(0.01)
            worst = max(worst, (time.time() - t) * 1000)
        return worst

    f = start()
    try:
        check(len(children(f)) == 1, 'the helper starts as the window opens')
        cmd(f, 'view.shading_rendered')
        f.pump(0.5)
        w = worst_frame(f)
        check(w < 500, f'Rendered while the pointer moves: at worst {w:.0f} ms a frame')
        pid = children(f)[0]
    finally:
        f.proc.terminate()
    f.proc.wait(timeout=10)
    time.sleep(0.3)
    check(not os.path.exists('/proc/' + pid) or open('/proc/%s/stat' % pid).read().split()[2] == 'Z', 'the helper goes with the window')

    # hung at its first run: the view stays live, F12 goes to the CPU after a moment
    f = start(BEEMODEL_GPU_HANG='1', BEEMODEL_GPU_TIMEOUT_MS='4000')
    try:
        cmd(f, 'view.shading_rendered')
        f.pump(0.3)
        w = worst_frame(f, 20)
        check(w < 500, f'a hung helper: the window stays live, at worst {w:.0f} ms a frame')
        f.pump(4.5)
        w = worst_frame(f, 20)
        check(len(children(f)) == 0 and f.proc.poll() is None, 'hung past its timeout: killed, the window goes on')
        check(w < 2000, f'then the CPU\'s view, at worst {w:.0f} ms a frame')
    finally:
        f.proc.kill()
    f.proc.wait(timeout=10)

    # the same with the viewport on the GPU: a late frame is the CPU's
    f = start(BEEMODEL_GPU_HANG='1', BEEMODEL_GPU_TIMEOUT_MS='3000', BEEMODEL_GPU_VIEW='on')
    try:
        f.pump(0.3)
        w = worst_frame(f, 20)
        check(w < 500, f'a hung helper under the GPU viewport: at worst {w:.0f} ms a frame')
    finally:
        f.proc.kill()
    f.proc.wait(timeout=10)

    # killed from outside under a window with the view on
    f = start()
    try:
        cmd(f, 'view.shading_rendered')
        f.pump(0.5)
        os.kill(int(children(f)[0]), signal.SIGKILL)
        f.pump(0.5)
        w = worst_frame(f, 10)
        check(f.proc.poll() is None and w < 2000, f'killed under the view: the window goes on ({w:.0f} ms)')
    finally:
        f.proc.kill()
    f.proc.wait(timeout=10)


def main():
    print(subprocess.run(['file', '-b', BIN], capture_output=True, text=True).stdout.strip()[:90])
    f = subprocess.run(['file', '-b', BIN], capture_output=True, text=True).stdout
    check('statically linked' in f, 'the main binary is static')
    if not os.access(HELPER, os.X_OK):
        print('  (no helper next to the binary: GPU checks skipped)')
        return 1 if REQUIRE else 0
    p, s, hello = helper()
    s.close()
    p.wait(timeout=20)
    st = struct.unpack('<I', hello[4:8])[0]
    if st != 0:
        print(f'  (the helper finds no device, status {st}: GPU checks skipped)')
        return 1 if REQUIRE else 0
    ty = struct.unpack('<I', hello[12:16])[0]
    rtx = ty & 0x100 != 0
    global DEVICE, helper_hello
    helper_hello = hello
    DEVICE = hello[16:64].split(b'\0')[0].decode()
    print('  device:', DEVICE, '(RTX)' if rtx else '')
    if '--untrusted' in sys.argv:
        untrusted()
        print(f'{len(FAILS)} failures')
        return 1 if FAILS else 0
    if '--view' in sys.argv:
        viewport()
        print(f'{len(FAILS)} failures')
        return 1 if FAILS else 0
    if '--window' in sys.argv:
        window()
        print(f'{len(FAILS)} failures')
        return 1 if FAILS else 0
    cpu = renders(rtx)
    fallbacks(cpu['default'])
    failures(cpu['default'], rtx, cpu['glass'])
    untrusted()
    live(rtx)
    viewport()
    window()
    shutil.rmtree(TMP, ignore_errors=True)
    print(f'{len(FAILS)} failures')
    for x in FAILS:
        print('  ' + x)
    return 1 if FAILS else 0


sys.exit(main())
