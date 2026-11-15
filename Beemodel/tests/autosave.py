#!/usr/bin/env python3
"""Autosave and recovery, by killing the process.

  - nothing is written before the 25th change, the 25th writes it (headless,
    and in a window of the fake compositor, tests/wl_fake.py)
  - kill -9, next start: the question, Recover brings every object back
  - the recovered scene has no file: Ctrl+S asks; the user's file is byte for byte
    what it was, whatever happened
  - a save, New, a clean exit: nothing is offered
  - a killed session whose window is alive is not offered (flock)
  - Not Now keeps it, Discard leaves it for file.recover
  - kill -9 at random moments while it autosaves all the time: the autosave on
    disk is always whole, and it opens with its objects
  - SIGTERM and a dead compositor: a last autosave
  - a damaged autosave is not offered and does no harm

    python3 tests/autosave.py BIN [kill-runs=40]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import atexit, glob, os, random, shutil, signal, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
DUP = ['--move', '615,360', '--key', 'shift+d']     # one change each (no grab follows)
HELD = []  # sessions waiting to be killed: killed at exit too, so a failed check never leaves one behind


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def tmp():
    return tempfile.mkdtemp(prefix='beeauto-', dir='/tmp')


def status(ui):
    for line in open(ui, errors='replace'):
        p = line.split('\t')
        if p[0] == 'status':
            return p[1]
    return ''


def labels(ui, kind):
    return [line.split('\t')[1] for line in open(ui, errors='replace') if line.split('\t')[0] == kind]


def objects(ui):
    s = status(ui).split('|')
    return int(s[1].split()[0]) if len(s) > 1 else -1


def well_formed(path):
    """The chunks walk from the header to the last byte, with OBJS among them."""
    d = open(path, 'rb').read()
    if len(d) < 8 or d[:4] != b'BEEM':
        return False
    o, objs = 8, False
    while len(d) - o >= 8:
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if size > len(d) - o - 8:
            return False
        objs = objs or tag == b'OBJS'
        o += 8 + size
    return o == len(d) and objs


def run(d, *args, hold=False, every=None, shot=None):
    """A headless session on autosave folder d; with hold it waits to be killed."""
    t = tmp()
    ui = os.path.join(t, 'ui.txt')
    cmd = [BIN, '--shot', os.path.join(t, 'o.ppm'), '--dump-ui', ui, '--autosave-dir', d]
    if every is not None:
        cmd += ['--autosave-every', str(every)]
    cmd += list(args)
    if hold:
        cmd.append('--hold')
    p = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)
    if hold:
        HELD.append(p)
    if not hold:
        _, err = p.communicate(timeout=300)
        return p.returncode, ui, err
    while True:
        line = p.stderr.readline()
        if not line or line.strip() == 'held':
            break
    return p, ui


def kill_held():
    for p in HELD:
        if p.poll() is None:
            p.kill()
            p.wait()


atexit.register(kill_held)


def kill(p):
    p.kill()
    p.wait()


def slots(d):
    return sorted(glob.glob(d + '/autosave-*.bee'))


def counting():
    d = tmp()
    p, ui = run(d, *DUP * 24, hold=True)
    check(not glob.glob(d + '/*.bee'), '24 changes: no autosave yet')
    kill(p)
    d = tmp()
    p, ui = run(d, *DUP * 25, hold=True)
    s = slots(d)
    check(len(s) == 1 and well_formed(s[0]), '25 changes: an autosave, whole')
    check(objects(ui) == 3 + 25, f'  the session has {objects(ui)} objects')
    kill(p)
    # preferences: never, or more often
    d = tmp()
    p, ui = run(d, *DUP * 30, hold=True, every=0)
    check(not glob.glob(d + '/*.bee'), 'interval 0: never')
    kill(p)
    d = tmp()
    p, ui = run(d, *DUP * 3, hold=True, every=3)
    check(len(slots(d)) == 1, 'interval 3: at the third change')
    kill(p)


def crash_and_recover():
    d = tmp()
    t = tmp()
    doc = t + '/mine.bee'
    # a file of the user's, then changes that are not saved
    p, ui = run(d, '--move', '615,360', '--key', 'enter', '--type', f'file.save {doc}', '--key', 'enter', '--key', 'esc', *DUP * 25, hold=True)
    want = open(doc, 'rb').read()
    n = objects(ui)
    check(n == 28, f'the scene before the crash: {n} objects')
    check(len(slots(d)) == 1, 'the autosave is there')
    if not slots(d):
        kill(p)
        return
    info = open(slots(d)[0][:-4] + '.info').read()
    check(doc in info, 'it knows which file it was')
    kill(p)
    rc, ui, err = run(d)
    check(labels(ui, 'dialog') == ['Recover unsaved work?'], 'the next start asks')
    # (asked, not answered: an exit keeps it)
    rc, ui, err = run(d, '--key', 'esc')
    check(not labels(ui, 'dialog'), 'Esc: the question goes')
    check(objects(ui) == 3, 'Not Now: the scene stays as it starts')
    rc, ui, err = run(d)
    check(labels(ui, 'dialog') == ['Recover unsaved work?'], 'Not Now: the next start asks again')
    p, ui = run(d, '--key', 'enter', hold=True)
    check(objects(ui) == n, f'Enter recovers: {objects(ui)} objects')
    check(any('Recovered' in x for x in labels(ui, 'toast')), 'and says so')
    check(open(doc, 'rb').read() == want, "the user's file is as it was")
    kill(p)
    # the recovered scene crashed too: offered again
    rc, ui, err = run(d, '--key', 'enter', '--key', 'ctrl+s')
    check(objects(ui) == n, 'killed again before a save: recovered again')
    check(any(x == 'Save' or x.startswith('Save') for x in labels(ui, 'button')), 'Ctrl+S on a recovered scene asks where')
    check(open(doc, 'rb').read() == want, "and has not touched the user's file")


def retired():
    # saved after the autosave: nothing to offer
    d, t = tmp(), tmp()
    p, ui = run(d, *DUP * 25, '--key', 'enter', '--type', f'file.save {t}/s.bee', '--key', 'enter', hold=True)
    check(not slots(d), 'a save retires the autosave')
    check(os.path.exists(d + '/autosave.bee'), 'file.recover keeps it')
    kill(p)
    rc, ui, err = run(d)
    check(not labels(ui, 'dialog'), 'killed after a save: nothing offered')
    # a clean exit
    d = tmp()
    rc, ui, err = run(d, *DUP * 25)
    rc, ui, err = run(d)
    check(not labels(ui, 'dialog'), 'after a clean exit: nothing offered')
    rc, ui, err = run(d, '--key', 'enter', '--type', 'file.recover', '--key', 'enter')
    check(objects(ui) == 28, f'file.recover opens the last autosave: {objects(ui)} objects')
    # File > New with changes given up
    d = tmp()
    p, ui = run(d, *DUP * 25, '--key', 'ctrl+n', '--click-label', "button:Don't Save", hold=True)
    check(objects(ui) == 3 or objects(ui) == 0, 'New: the scene went')
    check(not slots(d), "New, Don't Save: retired")
    kill(p)
    # a second window lives: its autosave is left alone
    d = tmp()
    p, ui = run(d, *DUP * 25, hold=True)
    rc, ui, err = run(d)
    check(not labels(ui, 'dialog'), 'a session still alive is not offered')
    rc, ui, err = run(d, '--key', 'enter', '--type', 'file.recover', '--key', 'enter')
    check(objects(ui) != 28, 'nor taken by file.recover')
    kill(p)
    rc, ui, err = run(d)
    check(labels(ui, 'dialog') == ['Recover unsaved work?'], 'once it dies, it is')
    # Discard
    rc, ui, err = run(d, '--move', '600,300', '--click-label', 'button:Discard')
    check(not slots(d) and os.path.exists(d + '/autosave.bee'), 'Discard: not offered, file.recover can')
    rc, ui, err = run(d)
    check(not labels(ui, 'dialog'), 'Discard: not asked again')


def storm(rounds):
    """Kill while it writes: the autosave on disk is whole, every time."""
    rng = random.Random(7)
    seen = 0
    # a heavy enough scene for the writes to take time: spheres
    big = []
    for _ in range(6):
        big += ['--key', 'enter', '--type', 'add sphere', '--key', 'enter', '--key', 'esc']
    d = tmp()
    for r in range(rounds):
        p = subprocess.Popen([BIN, '--shot', d + '/o.ppm', '--autosave-dir', d, '--autosave-every', '1', '--slow-writes', *big, *DUP * 400], stderr=subprocess.DEVNULL)
        time.sleep(0.02 + rng.random() * 0.4)
        p.send_signal(signal.SIGKILL)
        p.wait()
        for s in slots(d) + glob.glob(d + '/autosave.bee'):
            seen += 1
            if not well_formed(s):
                check(False, f'round {r}: {s} is not whole')
                shutil.copy(s, '/tmp/beeauto-damaged.bee')
                return
    check(seen >= rounds // 2, f'{rounds} kills during writes: {seen} autosaves on disk, all whole')
    run(d)   # (a start clears what the cut writes left)
    check(not glob.glob(d + '/*.tmp'), 'a start sweeps the cut-off temporary files')
    s = slots(d)
    if s:
        rc, ui, err = run(tmp(), '--key', 'enter', '--type', f'file.open {s[-1]}', '--key', 'enter')
        check(rc == 0 and objects(ui) > 3, f'the last one opens: {objects(ui)} objects')


def damaged():
    d = tmp()
    p, ui = run(d, *DUP * 25, hold=True)
    kill(p)
    s = slots(d)[0]
    b = bytearray(open(s, 'rb').read())
    open(s, 'wb').write(b[:len(b) // 2])
    rc, ui, err = run(d)
    check(rc == 0 and not labels(ui, 'dialog'), 'a cut autosave is not offered')
    check(os.path.exists(s), 'and is not deleted either')
    open(s[:-4] + '.info', 'wb').write(os.urandom(4000))
    rc, ui, err = run(d)
    check(rc == 0, 'a damaged info file does no harm')
    # a whole file with a nonsense info
    d = tmp()
    p, ui = run(d, *DUP * 25, hold=True)
    kill(p)
    open(slots(d)[0][:-4] + '.info', 'wb').write(os.urandom(4000))
    rc, ui, err = run(d, '--key', 'enter')
    check(rc == 0 and objects(ui) == 28, 'a whole autosave recovers whatever its info says')


def windowed():
    import wl_fake

    def session(home, n, finish):
        f = wl_fake.Fake(BIN, size=(1280, 800), env={'HOME': home, 'XDG_CACHE_HOME': os.path.join(home, 'cache')})
        HELD.append(f.proc)
        f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None, 20)
        f.enter(615, 360)
        f.motion(615, 360)
        f.pump(0.2)
        for _ in range(n):
            f.key(32, mods=1)                # Shift+D
            f.pump(0.05)
        f.pump(0.6)
        return f, finish(f)

    def after(f):
        f.proc.kill()
        f.proc.wait()

    def pixels(f):
        return f.surfaces[f.main().surface].get('pixels') if f.tops else None

    sub = 'beemodel-zig/autosave-*.bee'
    # the same keys: the 25th change writes it
    home = tmp()
    session(home, 24, after)
    at24 = glob.glob(f'{home}/cache/{sub}')
    home = tmp()
    session(home, 25, after)
    at25 = glob.glob(f'{home}/cache/{sub}')
    check(not at24 and len(at25) == 1, 'in a window: nothing after 24 changes, autosaved at the 25th')

    # kill -9, start again, Enter
    home = tmp()
    session(home, 25, after)
    f = wl_fake.Fake(BIN, size=(1280, 800), env={'HOME': home, 'XDG_CACHE_HOME': os.path.join(home, 'cache')})
    HELD.append(f.proc)
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None, 20)
    f.enter(615, 360)
    f.pump(1.0)
    a = pixels(f)
    f.key(28)
    f.pump(1.0)
    b = pixels(f)
    check(a is not None and b is not None and a != b, 'in a window: the question, then the scene')
    left = glob.glob(f'{home}/cache/{sub}')
    check(len(left) == 1, 'adopted: killed again, it is offered again')
    after(f)
    # SIGTERM: one last autosave of the changes since the last one
    home = tmp()

    def term(f):
        f.proc.send_signal(signal.SIGTERM)
        f.proc.wait(timeout=20)

    session(home, 3, term)
    check(len(glob.glob(f'{home}/cache/{sub}')) == 1, 'SIGTERM after 3 changes: a last autosave')
    # the compositor goes
    home = tmp()

    def gone(f):
        f.c.close()
        return f.proc.wait(timeout=20)

    _, code = session(home, 3, gone)
    check(code == 0, f"the compositor gone: an ordinary ending (exit {code})")
    check(len(glob.glob(f'{home}/cache/{sub}')) == 1, 'the compositor gone after 3 changes: a last autosave')


counting()
crash_and_recover()
retired()
damaged()
windowed()
storm(int(sys.argv[2]) if len(sys.argv) > 2 else 40)
print(f'autosave: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
