"""tests/play.py's s_window: play mode in a window.

Headless first (--key): F5 plays with the HUD's bar and its keys shown, F
flies, Esc asks (the bar's text changes), the status bar shows play's hints;
K keeps, Ctrl+Z takes it back, Esc D discards (the scene saved before F5,
chunk for chunk). Then BeeModel in the fake compositor (tests/wl_fake.py) with
pointer constraints and relative motion: the lock and the hidden cursor, the
view turned by relative motion, W walking at a frame rate, Esc unlocking and
asking, K and D ending it.

    playwin.run(BIN, level, T, check)   (BIN, ORIGINAL, level, T, check: ORIGINAL ignored)
"""
import os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile  # noqa: E402
import playlib as L  # noqa: E402


def bar_rect(img):
    """The HUD's bar: the rows of 0x1d2027 above the viewport's bottom (x0, y0, x1, y1)."""
    w, h = img.size
    px = img.load()
    best = None
    for y in range(h - 1, 60, -1):
        run = [x for x in range(0, w, 2) if px[x, y][:3] == (0x1d, 0x20, 0x27)]
        if len(run) > 200:
            if best is None:
                best = [min(run), y, max(run), y]
            best[1] = y
        elif best is not None and best[3] - best[1] > 4:
            break
        elif best is not None:
            best = None
    return tuple(best) if best else None


def port_shot(binary, args, path):
    r = L.run_port(binary, args, shot=path)
    from PIL import Image
    return Image.open(path).convert('RGB') if r is not None and r.returncode == 0 else None


def port_image(f):
    from PIL import Image
    s = f.surfaces[f.main().surface]
    b = f.buffers[s['last']]
    return Image.frombuffer('RGBX', (b['w'], b['h']), s['pixels'], 'raw', 'BGRX', b['stride'], 1).convert('RGB')


def port_window(binary, T, check):
    import wl_fake
    g = wl_fake.CORE + wl_fake.EXTRA + [('zwp_pointer_constraints_v1', 1), ('zwp_relative_pointer_manager_v1', 1)]
    f = wl_fake.Fake(binary, globals_=g, size=(1280, 800), env={'HOME': T})
    res = {}
    try:
        os.sched_setaffinity(f.proc.pid, {int(L.CPU)})
        f.until(lambda: f.frames > 0, 10)
        f.pump(0.5)
        f.enter(600, 300)
        f.motion(600, 300)
        f.pump(0.3)
        before = port_image(f)
        f.key(63)                                       # F5
        f.pump(0.4)
        res['locked'] = (f.locked is not None, f.relptr is not None, f.cursor_hidden, f.locks)
        f.key(33)                                       # F: fly (no floor in the default scene)
        f.pump(0.3)
        a = port_image(f)
        for _ in range(10):
            f.rel(20, 0)
            f.pump(0.02)
        f.pump(0.3)
        b = port_image(f)
        res['turned'] = sum(1 for x, y in zip(a.getdata(), b.getdata()) if x != y)
        n0, t0 = f.frames, time.time()
        f.serial += 1
        f.send(f.keyboard, 3, struct.pack('<IIII', f.serial, 1, 17, 1))     # W held a second
        while time.time() - t0 < 1.0:
            f.pump(0.05)
        f.serial += 1
        f.send(f.keyboard, 3, struct.pack('<IIII', f.serial, 1, 17, 0))
        res['fps'] = (f.frames - n0) / (time.time() - t0)
        f.pump(0.3)
        c = port_image(f)
        res['walked'] = sum(1 for x, y in zip(b.getdata(), c.getdata()) if x != y)
        f.key(1)                                        # Esc
        f.pump(0.4)
        res['asking'] = (f.locked is None, f.relptr is None, f.cursor_hidden)
        res['ask'] = port_image(f)
        f.key(37)                                       # K
        f.pump(0.4)
        res['kept'] = bar_rect(port_image(f)) is None
        f.key(63)
        f.pump(0.3)
        f.key(1)
        f.key(32)                                       # Esc D
        f.pump(0.4)
        res['discarded'] = (bar_rect(port_image(f)) is None, f.locked is None, f.locks)
        res['before'] = before
    finally:
        f.proc.kill()
        f.proc.wait()
    return res


def lit_in(img, r):
    """The bright pixels in a rectangle (the HUD's text on its dark bar)."""
    px = img.load()
    return sum(1 for y in range(r[1], r[3] + 1) for x in range(r[0], r[2] + 1) if sum(px[x, y][:3]) > 300)


def run(binary, *args):
    """run(BIN, level, T, check); the old run(BIN, ORIGINAL, level, T, check)
    is taken too (the ORIGINAL ignored)."""
    if len(args) == 4:
        args = args[1:]
    level, T, check = args
    # headless: the same keys
    D = f'{T}/win'
    os.makedirs(D, exist_ok=True)
    base = ['--op', f'file.open {level}', '--move', '600,300', '--key', 'f5', '--wait', '300']
    pi = port_shot(binary, ['--op', f'file.open {level}', '--move', '600,300', '--wait', '300'], f'{D}/pi.ppm')
    pw = port_shot(binary, base, f'{D}/pw.ppm')
    pf = port_shot(binary, base + ['--key', 'f', '--wait', '300'], f'{D}/pf.ppm')
    pa = port_shot(binary, base + ['--key', 'esc', '--wait', '300'], f'{D}/pa.ppm')
    if os.environ.get('PLAY_KEEP'):
        for k, im in (('idle', pi), ('walk', pw), ('fly', pf), ('ask', pa)):
            if im:
                im.save(os.path.join(os.environ['PLAY_KEEP'], f'p_{k}.png'))
    check(pi is not None and bar_rect(pi) is None, 'not playing: no HUD bar')
    bars = {}
    for name, im in (('walking', pw), ('flying', pf), ('asking', pa)):
        if im is None:
            check(False, f'{name}: BeeModel ran')
            continue
        r = bar_rect(im)
        bars[name] = (im, r)
        check(r is not None and 10 <= r[3] - r[1] <= 40 and r[2] - r[0] > 400 and lit_in(im, r) > 100,
              f'{name}: the HUD bar above the viewport\'s bottom, its text lit ({r})')
    if 'walking' in bars and 'asking' in bars and bars['walking'][1] and bars['asking'][1]:
        (a, ra), (b, rb) = bars['walking'], bars['asking']
        h = min(ra[3] - ra[1], rb[3] - rb[1])
        w = min(ra[2] - ra[0], rb[2] - rb[0])
        pa_, pb_ = a.load(), b.load()
        diff = sum(1 for y in range(h) for x in range(w) if pa_[ra[0] + x, ra[1] + y] != pb_[rb[0] + x, rb[1] + y])
        check(diff > 50, f'Esc: the bar asks (its text changed: {diff} pixels)')
    # the status bar's hints while playing (WASD walk, Space jump, F fly, Esc stop)
    if pi and pw:
        a, b = pi.load(), pw.load()
        w, h = pw.size
        diff = sum(1 for y in range(h - 20, h) for x in range(6, 400) if a[x, y] != b[x, y])
        check(diff > 100, f'the status bar shows play\'s hints while playing ({diff} pixels changed)')
    # K + Ctrl+Z, Esc D: the scene as before F5
    same = lambda a, b, tags: all(beefile.chunk(a, t) == beefile.chunk(b, t) for t in tags)
    tags = (b'OBJS', b'MODS', b'NTRE', b'FLDS')
    for k in range(4):
        if os.path.exists(f'{T}/q{k}.bee'):
            os.unlink(f'{T}/q{k}.bee')
    pargs = ['--op', f'file.open {level}', '--op', f'file.save_as {T}/q0.bee', '--move', '600,300', '--key', 'f5', '--wait', '100']
    pargs += ['--keydown', '17', '--wait', '300', '--keyup', '17', '--key', 'esc', '--key', 'k', '--op', f'file.save_as {T}/q1.bee', '--key', 'ctrl+z',
              '--op', f'file.save_as {T}/q2.bee', '--op', 'anim.frame 1', '--key', 'f5', '--wait', '100', '--keydown', '17', '--wait', '200', '--keyup', '17',
              '--key', 'esc', '--key', 'd', '--op', f'file.save_as {T}/q3.bee']
    r = L.run_port(binary, pargs)
    check(r is not None and r.returncode == 0, f'F5, W, Esc, K, Ctrl+Z, F5, W, Esc, D: BeeModel ran cleanly ({r.returncode if r else "timeout"})')
    okp = all(os.path.exists(f'{T}/q{k}.bee') for k in range(4))
    check(okp, 'the four scenes saved')
    if okp:
        check(all(beefile.objects(f'{T}/q{k}.bee') for k in range(4)), 'the saved scenes read back')
        check(not same(f'{T}/q0.bee', f'{T}/q1.bee', (b'OBJS',)), 'K kept what play moved')
        check(same(f'{T}/q0.bee', f'{T}/q2.bee', tags), 'Ctrl+Z after K: the scene before F5')
        check(same(f'{T}/q0.bee', f'{T}/q3.bee', tags), 'F5, W, Esc, D: the scene before F5')
    # in its own window: the lock, relative motion, the frame rate
    try:
        r = port_window(binary, T, check)
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        check(False, f'the window: {e!r}')
        return
    check(r['locked'][:3] == (True, True, True), f'the window: F5 locks the pointer, asks for relative motion, hides the cursor ({r["locked"]})')
    check(r['turned'] > 5000, f'relative motion turns the view ({r["turned"]} pixels changed)')
    check(r['walked'] > 5000 and r['fps'] > 15, f'W held a second flies on at {r["fps"]:.0f} frames a second ({r["walked"]} pixels changed)')
    check(r['asking'] == (True, True, False) and bar_rect(r['ask']) is not None, f'Esc unlocks the pointer, shows the cursor, asks ({r["asking"]})')
    check(r['kept'] and r['discarded'][0] and r['discarded'][1] and r['discarded'][2] == 2, f'K, then F5 Esc D: play ends, the HUD gone ({r["kept"]}, {r["discarded"]})')
