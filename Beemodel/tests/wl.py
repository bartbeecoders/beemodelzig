#!/usr/bin/env python3
"""The window against a fake compositor (tests/wl_fake.py): the clipboard, the
fractional scale, the panels' windows, a compositor with only the core globals,
and an idle window drawing nothing.   tests/wl.py BIN"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wl_fake
from wl_fake import Fake, CORE

BIN = sys.argv[1] if len(sys.argv) > 1 else 'zig-out-debug/bin/beemodel'
fails = 0


def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what)
    if not ok:
        fails += 1


def settle(f):
    """Until the frames stop (tooltips and toasts time out by themselves)."""
    n = -1
    for _ in range(40):
        n = f.frames
        f.pump(0.15)
        if f.frames == n:
            return True
    return False


def started(f):
    return f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)


# 1. only the core: it starts, draws and stays idle
f = Fake(BIN, CORE)
check(started(f), 'core globals only: first frame')
c = f.commits[0]
check(c[1:3] == f.size, 'core only: buffer %dx%d is the window' % c[1:3])
check('wl_data_device_manager' not in f.names, 'core only: no data device')
f.enter(500, 300)
f.pump(0.2)
settle(f)
before = f.frames
f.pump(1.2)
check(f.frames == before, 'core only: the idle window draws nothing (%d frames)' % (f.frames - before))
# (copy and paste inside the app still work without a data device: typed back)
f.key(28)                       # Enter: the console
for k in (35, 18, 38, 38, 24):  # hello
    f.key(k)
f.key(30, 4)                    # Ctrl+A
f.key(46, 4)                    # Ctrl+C
f.key(47, 4)                    # Ctrl+V over the selection: the same text
check(f.proc.poll() is None, 'core only: copy and paste keep it alive')
print(f.close()[-300:], end='')

# 2. the clipboard, both ways, with another program
f = Fake(BIN)
check(started(f), 'full compositor: first frame')
f.enter(500, 300)
f.pump(0.2)
f.key(28)                       # the console's line
for k in (35, 18, 38, 38, 24):
    f.key(k)
f.key(30, 4)
f.key(46, 4)
f.pump(0.1)
check(f.selection_source is not None, 'Ctrl+C sets the selection')
check('text/plain;charset=utf-8' in f.source_mimes.get(f.selection_source, []), 'it offers UTF-8 text')
check(f.ask_source() == b'hello', 'another program pastes what was copied')
f.key(45, 4)                    # Ctrl+X: the line is empty now
# someone else's selection arrives: Ctrl+V reads it, a line break becomes a space
f.send(f.selection_source, 2)   # cancelled
f.pump(0.1)
f.offer_selection('pasted\ntext', mimes=('text/plain',))
f.key(47, 4)
check(getattr(f, 'received', None) == 'text/plain', 'Ctrl+V asks the offer for its type')
f.key(30, 4)
f.key(46, 4)
f.pump(0.1)
check(f.ask_source() == b'pasted text', "another program's text was pasted, on one line")
print(f.close()[-300:], end='')

# 3. a reader that goes away does not hurt
f = Fake(BIN)
started(f)
f.enter(500, 300)
f.pump(0.2)
f.key(28)
f.key(35)
f.key(30, 4)
f.key(46, 4)
f.pump(0.1)
r, w = os.pipe()
os.close(r)
f.send(f.selection_source, 1, wl_fake.wstr('text/plain'), fds=[w])
os.close(w)
f.pump(0.3)
check(f.proc.poll() is None, 'a reader gone before the text is written: no signal')
print(f.close()[-300:], end='')

# 4. the fractional scale: the buffer in real pixels, the viewport on the window's size
f = Fake(BIN)
started(f)
f.enter(500, 300)
check(f.until(lambda: f.main().surface in f.fscale), 'a fractional scale object on the surface')
if f.main().surface in f.fscale:
    f.preferred_scale(180)
f.motion(400, 300)
ok = f.until(lambda: f.commits[-1][1:3] == (1500, 1050))
check(ok, 'scale 1.5: the buffer is 1500x1050 (%dx%d)' % f.commits[-1][1:3])
check(f.commits[-1][3] == (1000, 700), 'scale 1.5: the viewport maps it onto 1000x700 (%s)' % (f.commits[-1][3],))
settle(f)
before = f.frames
f.pump(1.2)
check(f.frames == before, 'every global: the idle window draws nothing (%d frames)' % (f.frames - before))
print(f.close()[-300:], end='')

# 5. a panel in a window of its own: a real toplevel, its own frames, and back
LETTERS = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}


def typed(f, s):
    for c in s:
        f.key(57 if c == ' ' else LETTERS[c])


for g, tag in ((CORE, 'core'), (wl_fake.CORE + wl_fake.EXTRA, 'full')):
    f = Fake(BIN, g)
    started(f)
    f.enter(900, 100)            # over the Outliner: the active area
    f.motion(905, 105)
    f.pump(0.1)
    f.key(61)                    # F3
    typed(f, 'open in new')
    f.key(28)
    ok = f.until(lambda: len(f.tops) == 2)
    check(ok, tag + ': Open in New Window makes a second toplevel')
    if ok:
        t = f.tops[1]
        check('Outliner' in t.title, tag + ': its title says what it shows (%s)' % t.title)
        check(f.until(lambda: f.surfaces[t.surface].get('pixels') is not None), tag + ': it draws into its own buffer')
        # the pointer goes in, and a click there is that window's
        n = f.frames
        f.leave()
        f.enter(60, 12, t.surface)
        f.pump(0.2)
        f.click(60, 12)          # (the header: a drag request, nothing else)
        f.motion(40, 60)
        f.pump(0.2)
        check(f.proc.poll() is None and f.frames > n, tag + ': input in it redraws (%d frames)' % (f.frames - n))
        # closing it docks the area back
        f.leave(t.surface)
        f.enter(500, 300)
        f.send(t.obj, 1)
        check(f.until(lambda: len(f.tops) == 1), tag + ': closing it destroys the toplevel')
        f.pump(0.2)
        check(f.proc.poll() is None, tag + ': and the app goes on')
    print(f.close()[-400:], end='')

print('wl fails', fails)
sys.exit(1 if fails else 0)
