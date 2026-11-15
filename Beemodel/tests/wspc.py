#!/usr/bin/env python3
"""Workspaces in .bee files (WSPC) and remembered: saved, opened and saved
again byte for byte, a floating panel kept in place, damaged chunks, the
workspaces file in ~/.config across starts (in the fake compositor).

    python3 tests/wspc.py BIN [damaged=200]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import glob, os, random, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
import wl_fake

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
T = tempfile.mkdtemp(prefix='beewsp-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*a, name='p'):
    ui = f'{T}/{name}.txt'
    r = subprocess.run([BIN, '--shot', f'{T}/{name}.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=120)
    return r, ui


def buttons(ui):
    return [l.split('\t')[1] for l in open(ui, errors='replace') if l.startswith('button\t')]


def editors(ui):
    return [l.split('\t')[1] for l in open(ui, errors='replace') if l.startswith('editor\t')]


# --- workspaces in a file, save -> open -> save -------------------------------------
a = f'{T}/a.bee'
r, ui = port('--op', 'workspace.new', '--op', 'workspace.rename Mine', '--op', 'area.split_side', '--op', 'workspace.set Shading', '--op', f'file.save {a}')
check(r.returncode == 0, 'BeeModel builds a workspace and saves')
c = beefile.chunk(a, b'WSPC')
cur, ws = beefile.workspaces(c)
names = [w['name'] for w in ws]
check(names == ['Modeling', 'Sculpt', 'CAD', 'Shading', 'Animation', 'World', 'Mine'], f'the file has them: {names}, current {names[cur]}')
check(cur == 3, 'the current one is Shading')
b = f'{T}/b.bee'
r, ui = port('--op', f'file.open {a}', '--op', f'file.save {b}', name='b')
check(r.returncode == 0, 'BeeModel opens it and saves it again')
check('Mine' in buttons(ui), 'its workspaces are the tabs')
c2 = beefile.chunk(b, b'WSPC')
check(c2 is not None and c2[:8] == c[:8], 'count and current kept')
check(c2 is not None and beefile.workspaces(c2) == beefile.workspaces(c), 'the same workspaces: names, trees, editors, cameras, panels, tabs')
b2 = f'{T}/b2.bee'   # (the first file's areas had not been laid out yet: their rectangles are settled from here)
r, ui = port('--op', f'file.open {b}', '--op', f'file.save {b2}', name='b2')
c3 = beefile.chunk(b2, b'WSPC')
check(c3 == c2, f'and once more: every record byte for byte ({len(c2 or b"")} bytes)')
r, ui = port('--op', f'file.open {a}', '--key', 'ctrl+s')
check('Save Anyway' not in buttons(ui), 'a file with workspaces is not "lossy" for them')
d = bytearray(open(a, 'rb').read())   # (a damaged chunk is: saving over it asks)
d[d.index(b'WSPC', 8) + 8] = 99
open(f'{T}/dm.bee', 'wb').write(d)
r, ui = port('--op', f'file.open {T}/dm.bee', '--key', 'ctrl+s')
check('Save Anyway' in buttons(ui), 'a damaged one is: saving over it asks')

# --- a floating panel, a maximized area -------------------------------------------
f = f'{T}/f.bee'
r, ui = port('--rclick', '1100,70', '--click-label', 'menuitem:Float Area', '--op', f'file.save {f}')
cur, ws = beefile.workspaces(beefile.chunk(f, b'WSPC'))
check(len(ws[0]['floats']) == 1, f"a panel in the file: {ws[0]['floats']}")
f3 = f'{T}/f3.bee'
r, ui = port('--op', f'file.open {f}', '--op', f'file.save {f3}')
_, ws3 = beefile.workspaces(beefile.chunk(f3, b'WSPC'))
check(ws3[0]['floats'] == ws[0]['floats'], 'opened and saved again: the same panel in the same place')

# --- damaged chunks ---------------------------------------------------------------
data = open(a, 'rb').read()
at = data.index(b'WSPC')
rng = random.Random(5)
bad = 0
for k in range(int(sys.argv[2]) if len(sys.argv) > 2 else 200):
    d = bytearray(data)
    for _ in range(rng.choice([1, 4, 40])):
        i = at + 8 + rng.randrange(11144)
        d[i] = rng.choice([0, 1, 2, 3, 31, 32, 200, 255, rng.randrange(256)])
    if rng.random() < 0.1:   # the count, the size
        struct.pack_into('<I', d, at + 8, rng.choice([0, 13, 12, 0xffffffff, 7]))
    if rng.random() < 0.1:
        struct.pack_into('<I', d, at + 12, rng.choice([99, 0xffffffff]))
    open(f'{T}/d.bee', 'wb').write(d)
    r, ui = port('--op', f'file.open {T}/d.bee', '--key', 'ctrl+pagedown', '--click-label', 'button:+', '--move', '600,300', '--key', 'f6')
    if r.returncode not in (0, 2):
        bad += 1
        print(r.stderr[-400:])
        break
check(bad == 0, 'damaged WSPC chunks: no crash, whatever the bytes')

# --- remembered (in the fake compositor: tests/wl_fake.py) --------------------------
def window(home):
    x = wl_fake.Fake(BIN, env={'HOME': home})
    x.until(lambda: x.frames > 0 and x.keyboard is not None and x.pointer is not None, 10)
    x.pump(1.0)
    return x


def gone(x):
    x.proc.kill()
    x.proc.wait()


home = tempfile.mkdtemp(prefix='beewsph-', dir='/tmp')
x = window(home)
x.enter(600, 300)
x.key(109, 4)              # Ctrl+PageDown: Sculpt
x.pump(0.5)
gone(x)
w = home + '/.config/beemodel-zig/workspaces'
check(os.path.exists(w), 'a switch writes ~/.config/beemodel-zig/workspaces')
cur, ws = beefile.workspaces(open(w, 'rb').read()) if os.path.exists(w) else (-1, [])
check(cur == 1 and ws[1]['name'] == 'Sculpt', 'with the workspace in use')
# the next start takes them
x = window(home)
x.enter(600, 300)
x.key(109, 4)              # to CAD: written again, from what it started with
x.pump(0.5)
gone(x)
cur2, ws2 = beefile.workspaces(open(w, 'rb').read()) if os.path.exists(w) else (-1, [])
check(cur2 == 2, f'the next start went on from Sculpt, Ctrl+PageDown: {ws2[cur2]["name"] if ws2 else "none"}')
open(w, 'wb').write(os.urandom(5000))
x = window(home)
check(x.proc.poll() is None and x.frames > 0, 'a damaged workspaces file: a normal start')
gone(x)

print(f'wspc: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
