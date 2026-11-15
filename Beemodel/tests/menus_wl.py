#!/usr/bin/env python3
"""The menus (menus.zig: the bar's drop-downs, context menus and their
submenus) in BeeModel's window in a fake compositor (tests/wl_fake.py), the
entries found through its own MCP ui_tree:

  * open and closed: every menu and submenu drawn with its border where its
    entries are (a submenu beside its entry, kept in the window: on the
    left when there is no room, above the bottom), closed when it should be;
  * the pointer: hover opens and switches submenus (a diagonal path over
    other entries too), the overlap strip is the submenu's, entries run on
    the button's release (press on a title, drag into a submenu, let go), the
    release of the right-click that opened a context menu picks nothing
    unless the pointer moved 4 px, a release outside keeps the menu, a press
    outside closes it (a left press on a widget presses it too), sliding over
    the bar's titles switches menus;
  * the keys: F10, Up / Down, Right / Left, Enter, Esc one level, other keys
    go on to the app with the menu open (Ctrl+Space: the area maximized);
  * what runs: a theme from View > Theme (the menu bar's colour changes, and
    back), objects duplicated / hidden / deleted from the outliner's and the
    viewport's context menus (the scene saved and its objects counted), a
    greyed entry in a submenu (the menu closes, nothing runs), File > Open
    Recent (the recent scenes' names; one opened);
  * near the window's edges: a smaller window, a context menu at the right
    edge.

    python3 tests/menus_wl.py BIN

BEE_CPU (default 20) pins BeeModel; MW_ONLY=a,b,... runs some groups.
Ends with "menus_wl: fails N".
"""
import os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
import json, socket
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
CPU = int(os.environ.get('BEE_CPU', '20'))
ONLY = [x for x in os.environ.get('MW_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beemenu', dir='/tmp')   # (lower case: typed into the console)
HELD = []
LMB, RMB = 0x110, 0x111
K_ESC, K_TAB, K_ENTER, K_UP, K_DOWN, K_LEFT, K_RIGHT, K_F10 = 1, 15, 28, 103, 108, 105, 106, 68
DROP_BORDER = (0x10, 0x11, 0x14)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(g):
    return not ONLY or g in ONLY


def _real_config():
    import pwd
    h = pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                st = os.stat(os.path.join(p, n))
                out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_config()


def home(kind='port', recent=()):
    """A HOME for BeeModel: the context menus as lists (not the wheel),
    tooltips late (the shots are not timed), its recent scenes."""
    h = tempfile.mkdtemp(prefix='h', dir=T)
    os.makedirs(f'{h}/.config/beemodel-zig')
    open(f'{h}/.config/beemodel-zig/prefs', 'w').write('wheel_menu 0\ntooltip_ms 5000\n' + ''.join(f'recent_file {p}\n' for p in recent))
    return h


ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
ROW.update({str(i): i + 1 for i in range(1, 10)})


class Port:
    """BeeModel in the fake compositor, an MCP client on its socket."""

    def __init__(self, size, recent=()):
        import wl_fake
        self.home = home('port', recent)
        self.f = wl_fake.Fake(BIN, size=size, env={'BEE_CPU': str(CPU), 'HOME': self.home, 'XDG_RUNTIME_DIR': self.home,
                                                   'BEEMODEL_AGENT_PERMISSION': 'files'})
        HELD.append(self.f.proc)
        os.sched_setaffinity(self.f.proc.pid, {CPU})
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None)
        self.f.enter(640, 400)
        self.f.motion(640, 400)
        self.f.pump(0.3)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(100):
            try:
                self.s.connect(os.path.join(self.home, 'beemodel.sock'))
                break
            except OSError:
                self.f.pump(0.1)
        self.s.setblocking(False)
        self.buf = b''
        self.rid = 0
        self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'menus', 'version': '1'}})

    def call(self, method, params=None, timeout=10.0):
        self.rid += 1
        rid = self.rid
        self.s.sendall(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params or {}}).encode() + b'\n')
        end = time.time() + timeout
        while time.time() < end:
            while b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get('id') == rid:
                    return r
            self.f.pump(0.01)
            try:
                c = self.s.recv(1 << 22)
                if c == b'':
                    return None
                self.buf += c
            except BlockingIOError:
                pass
        return None

    def tree(self):
        """the widgets of the last frame (ui_tree)"""
        self.f.pump(0.15)
        r = self.call('tools/call', {'name': 'ui_tree', 'arguments': {}})
        try:
            return json.loads(r['result']['content'][0]['text'])['widgets']
        except (TypeError, KeyError, IndexError, ValueError):
            return []

    def move(self, x, y):
        self.f.motion(x, y)
        self.f.pump(0.08)

    def btn(self, down, b=LMB):
        self.f.button(b, down)
        self.f.pump(0.08)

    def key(self, code, mods=0):
        self.f.key(code, mods)
        self.f.pump(0.05)

    def image(self):
        self.f.pump(0.25)
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s['last']]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def save(self, path):
        """file.save_as typed into the console's line"""
        self.key(K_ENTER)
        for c in 'file.save_as ' + path:
            if c == '_':
                self.key(12, 1)
            else:
                self.key(ROW[c])
        self.key(K_ENTER)
        t0 = time.time()
        while not os.path.exists(path) and time.time() - t0 < 30:
            self.f.pump(0.1)
        self.f.pump(0.3)
        self.key(K_ESC)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        self.f.proc.kill()
        self.f.proc.wait()


def kill_held():
    for p in HELD:
        try:
            p.kill()
            p.wait(5)
        except Exception:
            pass


class Both:
    """BeeModel in its window; its ui_tree for where things are. (The name from
    when another program ran beside it.)"""

    def __init__(self, size=(1280, 800), recent=()):
        self.size = size
        self.p = Port(size, recent)
        self.last = []       # the menus' rectangles last seen open
        self.bar0 = bar_px(self.p.image())   # the menu bar's colour as it starts

    def move(self, x, y):
        self.p.move(x, y)

    def path(self, pts, steps=6):
        """move along the segments in small steps (a diagonal: every entry
        on the way is passed over)"""
        x0, y0 = pts[0]
        self.move(x0, y0)
        for x1, y1 in pts[1:]:
            for s in range(1, steps + 1):
                self.move(x0 + (x1 - x0) * s // steps, y0 + (y1 - y0) * s // steps)
            x0, y0 = x1, y1

    def btn(self, down, b=LMB):
        self.p.btn(down, b)

    def click(self, x, y, b=LMB):
        self.move(x, y)
        self.btn(True, b)
        self.btn(False, b)

    def key(self, code, mods=0):
        self.p.key(code, mods)

    def items(self):
        """the open menus' entries, each with its level (0 the menu, 1 its
        submenu: the entries of one menu share their x)"""
        its = [dict(w) for w in self.p.tree() if w['kind'] == 'menuitem']
        xs = []
        for w in its:
            if w['x'] not in xs:
                xs.append(w['x'])
            w['level'] = xs.index(w['x'])
        return its

    def item(self, label, level=None):
        its = [w for w in self.items() if w['label'] == label and (level is None or w.get('level') == level)]
        assert its, f'no menu entry {label!r} open'
        return its[-1]

    def title(self, label):
        return [w for w in self.p.tree() if w['kind'] == 'menu' and w['label'] == label][0]

    def close(self):
        self.p.close()


def boxes(items, popups=()):
    """the menus: Zui's popups (its records), each holding the entries of a
    level; else (BeeModel's own, in a panel's window) from their entries:
    (x, y, w, h) a level"""
    out = []
    for lv in (0, 1):
        e = [w for w in items if w.get('level') == lv]
        if not e:
            continue
        for p in popups:
            px, py, pw, ph = p['x'], p['y'], p['w'], p['h']
            if all(px <= w['x'] and w['x'] + w['w'] <= px + pw and py <= w['y'] and w['y'] + w['h'] <= py + ph for w in e):
                out.append((px, py, pw, ph))
                break
    if out:
        return out
    for lv in (0, 1):
        e = [w for w in items if w.get('level') == lv]
        if e:
            out.append((e[0]['x'], min(w['y'] for w in e) - 4, e[0]['w'], max(w['y'] for w in e) + 28 - (min(w['y'] for w in e) - 4)))
    return out


def menu_at(img, bx):
    """is a menu drawn in these boxes (their top and left edges the border's
    colour)"""
    if not bx:
        return False
    for (x, y, w, h) in bx:
        W, H = img.size
        edge = [(xx, y) for xx in range(max(0, x + 8), min(W, x + w - 8))] + [(x, yy) for yy in range(max(0, y + 8), min(H, y + h - 8)) if 0 <= x < W]
        if not edge or sum(1 for p in edge if max(abs(img.getpixel(p)[i] - DROP_BORDER[i]) for i in range(3)) <= 3) < len(edge) * 0.9:
            return False
    return True


def edges(img, bx, ref=DROP_BORDER):
    """each menu's border exactly at the box's left, right and top edges
    (the pixel compare allows a pixel's shift for the text)"""
    W, H = img.size
    bad = []
    near = lambda p: max(abs(img.getpixel(p)[i] - ref[i]) for i in range(3)) <= 3
    for k, (x, y, w, h) in enumerate(bx):
        # (what a later box - the submenu, on top - covers is left out)
        free = lambda p: not any(bx2[0] - 7 <= p[0] < bx2[0] + bx2[2] + 7 and bx2[1] - 7 <= p[1] < bx2[1] + bx2[3] + 7 for bx2 in bx[k + 1:])
        lines = [[(col, yy) for yy in range(max(0, y + 8), min(H, y + h - 8))] for col in (x, x + w - 1) if 0 <= col < W]
        lines.append([(xx, y) for xx in range(max(0, x + 8), min(W, x + w - 8)) if 0 <= y < H])
        for ln in lines:
            ln = [p for p in ln if free(p)]
            if ln and sum(1 for p in ln if near(p)) < len(ln) * 0.9:
                bad.append((x, y, w, h))
    return bad


def look(b, name, open_=True, tol=14):
    """The menus open where their entries are, drawn with their borders; or
    closed. (A, B: the window's picture twice, for the callers' shape.)"""
    B = b.p.image()
    its = b.items()
    bx = boxes(its, [w for w in b.p.tree() if w['kind'] == 'popup'])
    if bx:
        b.last = bx
        lv = ', '.join(f'{x},{y} {w}x{h}' for x, y, w, h in bx)
        ref = B.getpixel((bx[0][0] + bx[0][2] // 2, bx[0][1]))    # (the theme's border)
        eb = edges(B, bx, ref)
        inside = all(x >= 0 and y >= 0 and x + w <= B.size[0] and y + h <= B.size[1] for x, y, w, h in bx)
        check(open_ and not eb and inside, f'{name}: open: {len(bx)} level{"s" if len(bx) > 1 else ""} ({lv}), borders where the entries are, in the window (off: {eb})')
    else:
        was = b.last
        check(not open_ and not menu_at(B, was), f'{name}: closed' + (' (one still shows)' if menu_at(B, was) else ''))
    return B, B


def bar_px(img):
    return img.getpixel((img.size[0] - 60, 44))


def theme_same(b, name, changed):
    p = bar_px(b.p.image())
    check((p != b.bar0) == changed, f'{name}: the menu bar\'s colour {p} ({"changed" if p != b.bar0 else "as it started"} {b.bar0})')


def objects(b, name, want_n=None, mask=0xffffffff):
    fn = ''.join(c if c.isalnum() else '_' for c in name.lower())[:30]
    pp = f'{T}/{fn}_p.bee'
    if os.path.exists(pp):
        os.remove(pp)
    b.p.save(pp)
    try:
        op = [(o['name'], o['type'], o['flags'] & mask) for o in beefile.objects(pp)]
    except Exception as e:  # noqa
        check(False, f'{name}: saved ({e})')
        return None
    ok = want_n is None or len(op) == want_n
    if mask != 0xffffffff:
        ok = ok and any(f for _, _, f in op)
    check(ok, f'{name}: the objects ({len(op)}: {op})')
    return op


def esc_all(b):
    for _ in range(3):
        b.key(K_ESC)


# --- the groups --------------------------------------------------------------------

def g_bar():
    """bar menus, hover into submenus, the overlap strip, release, keys"""
    print('-- the bar\'s menus and their submenus', flush=True)
    b = Both()
    try:
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        look(b, 'file')
        imp = b.item('Import')
        b.move(imp['x'] + 40, imp['y'] + 12)
        look(b, 'file > import (hover)')
        b.move(imp['x'] + 40, b.item('Export')['y'] + 24 + 4)
        look(b, 'the pointer on the menu\'s separator: Import\'s submenu stays')
        b.move(imp['x'] + 40, imp['y'] + 12)
        # (the keys go to the innermost open menu: Import's submenu; Esc
        # closes one level, as the menus have since they are Zui's)
        b.key(K_DOWN)
        look(b, 'Down: Import\'s submenu open, its first entry lit')
        b.key(K_ESC)
        check(len(b.items()) > 0 and not [w for w in b.items() if w.get('level') == 1], 'Esc: the submenu closed, the menu open')
        b.key(K_ESC)
        look(b, 'Esc again: all closed', False)
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        b.move(imp['x'] + 40, imp['y'] + 12)
        # the overlap strip (the submenu over the menu's right edge): the
        # pointer on a row of the menu (Screenshot) is the submenu's
        sub = b.item('Import OBJ...', 1)
        b.move(sub['x'] + 1, imp['y'] + 12 + 3 * 24 - 4)
        look(b, 'file > import, the pointer in the overlap strip')
        b.move(imp['x'] + 40, b.item('Export')['y'] + 12)
        look(b, 'file > export (hover switches the submenu)')
        b.move(imp['x'] + 40, b.item('Screenshot')['y'] + 12)
        look(b, 'file > screenshot (hover closes the submenu)')
        b.move(imp['x'] + 40, b.item('Recover Autosave')['y'] + 12)
        b.move(imp['x'] + 40, b.item('Open Recent')['y'] + 12)
        look(b, 'file > open recent (none yet: one greyed blank entry)')
        # sliding onto another title with a submenu open switches the menu
        t = b.title('Add')
        b.path([(imp['x'] + 40, b.item('Open Recent')['y'] + 12), (t['x'] + 20, t['y'] + 12)], 4)
        look(b, 'slid onto Add: its menu, nothing lit')
        # the View menu: Theme's submenu, a click in the overlap strip runs
        # the submenu's entry (High Contrast), not the menu's
        t = b.title('View')
        b.move(t['x'] + 20, t['y'] + 12)
        th = b.item('Theme')
        b.move(th['x'] + 40, th['y'] + 12)
        look(b, 'view > theme')
        hc = b.item('High Contrast', 1)
        b.move(hc['x'] + 1, hc['y'] + 12)
        look(b, 'view > theme, High Contrast lit through the overlap strip')
        b.move(hc['x'] + 60, hc['y'] + 24 + 4)
        look(b, 'on the submenu\'s separator: nothing lit in it')
        b.move(hc['x'] + 1, hc['y'] + 12)
        b.btn(True)
        look(b, 'a press in the menu: nothing yet')
        b.btn(False)
        theme_same(b, 'a click in the overlap strip ran High Contrast', True)
        look(b, 'the menu closed after it ran', False, tol=24)
        # back to Dark by press on the title, drag down into the submenu,
        # release on the entry
        t = b.title('View')
        b.move(t['x'] + 20, t['y'] + 12)
        b.btn(True)
        th = b.item('Theme')
        b.path([(t['x'] + 20, t['y'] + 12), (th['x'] + 40, th['y'] + 12)], 6)
        dk = b.item('Dark', 1)
        b.path([(th['x'] + 40, th['y'] + 12), (dk['x'] + 60, dk['y'] + 12)], 4)
        # (High Contrast: the text engines' edge pixels differ by up to 20)
        look(b, 'press on View, dragged to Theme > Dark', tol=24)
        b.btn(False)
        theme_same(b, 'released on Dark: it ran', False)
        look(b, 'closed after it ran', False)
        # a diagonal from Analysis to its submenu's last entry passes over
        # Measure .. Theme: the submenus follow the pointer
        t = b.title('View')
        b.click(t['x'] + 20, t['y'] + 12)
        an = b.item('Analysis')
        b.move(an['x'] + 150, an['y'] + 12)
        last = [w for w in b.items() if w.get('level') == 1][-1]
        b.path([(an['x'] + 150, an['y'] + 12), (last['x'] + 40, last['y'] + 12)], 12)
        look(b, 'a diagonal from Analysis toward its last entry')
        # a release outside after a drag keeps the menu open
        esc_all(b)
        t = b.title('Help')
        b.move(t['x'] + 20, t['y'] + 12)
        b.btn(True)
        b.path([(t['x'] + 20, t['y'] + 12), (700, 300)], 4)
        b.btn(False)
        look(b, 'press on Help, released over the viewport: still open')
        b.click(700, 300)
        look(b, 'a click outside closes it', False)
        # the keyboard
        b.key(K_F10)
        look(b, 'F10: File, its first entry lit')
        for _ in range(5):
            b.key(K_DOWN)
        look(b, 'Down x5: Import lit (separators skipped)')
        b.key(K_RIGHT)
        look(b, 'Right: into the submenu, its first entry lit')
        b.key(K_DOWN)
        b.key(K_DOWN)
        look(b, 'Down x2 in the submenu')
        b.key(K_LEFT)
        look(b, 'Left: back out, the submenu closed')
        b.key(K_ENTER)
        look(b, 'Enter on Import: its submenu, keyboard in it')
        b.key(K_ESC)
        look(b, 'Esc: one level')
        b.key(K_UP)
        b.key(K_UP)
        look(b, 'Up x2 (over a separator)')
        b.key(K_LEFT)
        look(b, 'Left on the menu: the previous one (Help), its first lit')
        b.key(K_RIGHT)
        look(b, 'Right on an entry without a submenu: the next menu (File)')
        b.key(K_LEFT)
        b.key(K_LEFT)
        b.key(K_LEFT)
        b.key(K_RIGHT)
        look(b, 'Left x3, Right: AI')
        b.key(K_ESC)
        t = b.title('Help')
        b.click(t['x'] + 20, t['y'] + 12)
        b.key(K_UP)
        look(b, 'Up from nothing lit: the last entry')
        b.key(K_ESC)
        look(b, 'Esc: closed', False)
        # other keys go on to the app, the menu staying open: Tab
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        # (Ctrl+Space: Maximize Area, a key both programs take anywhere)
        b.key(57, 4)
        A, B = look(b, 'Ctrl+Space with the File menu open: still open')
        # (the outliner's Cube row, there until the area is maximized: asked
        # of the widget tree, not a pixel, as the outliner's look may change)
        row = lambda _im: any(w['kind'] == 'row' and w['label'] == 'Cube' for w in b.p.tree())
        check(not row(B), f'Ctrl+Space went on to the app: the area maximized, the outliner gone ({not row(B)})')
        b.key(K_ESC)
        t = b.title('View')
        b.click(t['x'] + 20, t['y'] + 12)
        look(b, 'View with the area maximized')
        b.key(57, 4)
        A, B = look(b, 'again with View open: the menu open')
        check(row(B), f'and the area back: the outliner there ({row(B)})')
        b.key(K_ESC)
    finally:
        b.close()


def g_grey():
    """a greyed entry in a submenu: the menu closes, nothing runs"""
    print('-- greyed entries', flush=True)
    b = Both()
    try:
        t = b.title('Mesh')
        b.click(t['x'] + 20, t['y'] + 12)
        mg = b.item('Merge')
        b.move(mg['x'] + 40, mg['y'] + 12)
        look(b, 'mesh > merge (greyed in object mode)')
        e = [w for w in b.items() if w.get('level') == 1][0]
        b.click(e['x'] + 40, e['y'] + 12)
        look(b, 'a click on a greyed entry closes the menu', False)
        objects(b, 'greyed: nothing ran', 3)
    finally:
        b.close()


def g_outliner():
    """the outliner's context menu: right-click, release, fresh"""
    print('-- the outliner\'s context menu', flush=True)
    b = Both()
    try:
        cx, cy = 1080, 134      # the outliner's Cube row
        # right-click and let go where it opened: nothing picked, it stays
        b.click(cx, cy, RMB)
        look(b, 'right-click on Cube: its menu at the pointer, open after the release')
        hd = b.item('Hide')
        b.click(hd['x'] + 40, hd['y'] + 12)
        look(b, 'clicked Hide: closed', False)
        objects(b, 'outliner > hide', 3)
        # right press, a jitter of 6 px down, release: the first entry runs
        # (the release of the opening press picks once the pointer moved 4 px)
        b.move(cx, cy - 20)
        b.btn(True, RMB)
        b.move(cx + 2, cy - 20 + 6)
        look(b, 'right press, moved 6 px: Duplicate lit under the pointer')
        b.btn(False, RMB)
        look(b, 'released: it ran', False)
        objects(b, 'outliner: a right press moved 6 px and let go duplicated', 4)
        # 2 px: nothing
        b.move(cx, cy - 20)
        b.btn(True, RMB)
        b.move(cx + 1, cy - 20 + 2)
        b.btn(False, RMB)
        look(b, 'right press, moved 2 px, released: still open')
        # press, drag onto Delete, release (the right button)
        de = b.item('Delete')
        b.btn(True, RMB)
        b.path([(cx + 1, cy - 18), (de['x'] + 50, de['y'] + 12)], 5)
        b.btn(False, RMB)
        look(b, 'right press dragged onto Delete, released: closed', False)
        objects(b, 'outliner: dragged onto Delete', 3)
    finally:
        b.close()


def g_viewport():
    """the viewport's context menu (the list: wheel_menu 0), near the right
    edge: kept in the window, its Boolean submenu on the left, on top"""
    print('-- the viewport\'s context menu at the window\'s right edge', flush=True)
    b = Both()
    try:
        b.click(1008, 520, RMB)       # (278 wide: kept 1002 from the left)
        look(b, 'right-click in the viewport at its right edge')
        bo = b.item('Boolean')
        b.move(bo['x'] + 60, bo['y'] + 12)
        look(b, 'Boolean: its submenu on the left')
        subs = [w for w in b.items() if w.get('level') == 1]
        # the submenu over the menu's left edge: a row of the menu there
        b.move(subs[0]['x'] + subs[0]['w'] - 2, subs[-1]['y'] + 12)
        look(b, 'the pointer where the submenu covers the menu: the submenu\'s')
        b.click(subs[-1]['x'] + subs[-1]['w'] - 2, subs[-1]['y'] + 12)
        look(b, 'a click there: the submenu\'s greyed entry, closed', False)
        objects(b, 'viewport: nothing ran', 3)
        # near the bottom: the menu moves up, an entry (Hide) under the
        # pointer; the release picks nothing (it did not move 4 px)
        b.click(600, 600, RMB)
        look(b, 'right-click low in the viewport: open, nothing picked')
        b.key(K_ESC)
        b.click(600, 330, RMB)
        dup = b.item('Duplicate')
        b.click(dup['x'] + 40, dup['y'] + 12)
        objects(b, 'the release over Hide ran nothing; Duplicate ran', 4)
    finally:
        b.close()


def g_small():
    """a smaller window: the submenu kept above the bottom, on the left"""
    print('-- a smaller window', flush=True)
    b = Both((590, 650))
    try:
        t = b.title('View')
        b.click(t['x'] + 20, t['y'] + 12)
        look(b, '590x650: View')
        th = b.item('Theme')
        b.move(th['x'] + 60, th['y'] + 12)
        look(b, 'Theme: its submenu on the left, above the bottom')
        subs = [w for w in b.items() if w.get('level') == 1]
        nd = [w for w in subs if w['label'] == 'Nord'][0]
        b.move(nd['x'] + nd['w'] - 2, nd['y'] + 12)
        look(b, 'the pointer where the submenu covers the menu')
        b.btn(True)
        b.btn(False)
        theme_same(b, 'a click there ran Nord', True)
    finally:
        b.close()


def g_recent():
    """File > Open Recent: the scenes' names; one opened"""
    print('-- File > Open Recent', flush=True)
    d = tempfile.mkdtemp(prefix='rec', dir=T)
    # two scenes made by BeeModel (--run)
    oh = home('port')
    for name, code in (('two.bee', 'n = count()\nfor i in 0..n { delete(name(0)) }\nop("create.cube")\nop("create.sphere")\n'),
                       ('one.bee', 'n = count()\nfor i in 0..n { delete(name(0)) }\nop("create.torus")\n')):
        open(f'{d}/s.bees', 'w').write(code + f'op("file.save_as", "{d}/{name}")\n')
        subprocess.run(['taskset', '-c', str(CPU), BIN, '--run', f'{d}/s.bees'], capture_output=True, timeout=120, env=dict(os.environ, HOME=oh))
    ok = os.path.exists(f'{d}/two.bee') and os.path.exists(f'{d}/one.bee')
    check(ok, 'two scenes made by BeeModel')
    if not ok:
        return
    b = Both(recent=(f'{d}/one.bee', f'{d}/two.bee'))
    try:
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        rc = b.item('Open Recent')
        b.move(rc['x'] + 40, rc['y'] + 12)
        look(b, 'Open Recent: the scenes\' names')
        e = b.item('two.bee', 1)
        b.click(e['x'] + 40, e['y'] + 12)
        b.p.f.pump(1.0)
        look(b, 'opened: closed', False)
        objects(b, 'two.bee opened from Open Recent', 2)
    finally:
        b.close()


def port_dump(*args):
    """the port's widgets (headless --dump-ui, 1280x800) after args"""
    h = tempfile.mkdtemp(prefix='d', dir=T)
    open(f'{h}/p.txt', 'w').close()
    subprocess.run(['taskset', '-c', str(CPU), BIN, '--shot', f'{h}/p.png', '--dump-ui', f'{h}/u.txt', '--size', '1280x800', *args],
                   capture_output=True, timeout=120, env=dict(os.environ, HOME=h))
    rows = []
    for ln in open(f'{h}/u.txt', errors='replace'):
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 4:
            try:
                x, y, w, hh = map(int, p[2].split())
            except ValueError:
                continue
            rows.append((p[0], p[1], x, y, w, hh, p[3] == 'on'))
    return rows


def g_pass():
    """presses outside a menu: a widget takes the press too; an area's
    editor type opens its menu (its own again: closes); the header's menus
    at the pointer"""
    print('-- presses outside a menu, menus of the areas', flush=True)
    rows = port_dump()
    pvis = [r for r in rows if r[0] == 'checkbox' and r[1] == 'Visible'][0]
    ptype = [r for r in rows if r[0] == 'editor' and r[1] == '3D Viewport'][0]
    b = Both()
    try:
        # a press on the viewport or an outliner's row only closes the menu
        for (x, y, what) in ((700, 300, 'the viewport'), (1080, 114, 'the outliner\'s Light')):
            t = b.title('Help')
            b.click(t['x'] + 20, t['y'] + 12)
            b.click(x, y)
            look(b, f'a click on {what}: the menu closed', False)
        objects(b, 'and nothing else (the selection kept)', 3)
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        look(b, 'File open')
        b.p.move(pvis[2] + 7, pvis[3] + pvis[5] // 2)
        b.btn(True)
        b.btn(False)
        look(b, 'a click on the Properties\' Visible: the menu closed', False)
        objects(b, 'the click also unticked Visible (Cube hidden)', 3, 0x200)
        # the editor type with a menu open: that area's menu; again: closes
        t = b.title('File')
        b.click(t['x'] + 20, t['y'] + 12)
        b.p.move(ptype[2] + 26, ptype[3] + 10)
        b.btn(True)
        b.btn(False)
        its = b.items()
        dump = port_dump('--click', f'{ptype[2] + 26},{ptype[3] + 10}')
        po = [r for r in dump if r[0] == 'menuitem']
        pp = [r for r in dump if r[0] == 'popup']
        prel = (po[0][2] - (ptype[2] - 4), po[0][3] - (ptype[3] - 2)) if po else None
        check(po and its and abs(prel[0]) <= 8 and 0 < prel[1] <= 40, f'the editor type\'s menu under the area\'s header, at its left ({prel} from the area)')
        B = b.p.image()
        # (the menu's box: Zui's popup; BeeModel's drew it 4 around its entries)
        pbox = [tuple(pp[0][2:6])] if pp else [(po[0][2], po[0][3] - 4, po[0][4], 8 + 24 * len(po))] if po else []
        check(its and menu_at(B, pbox), 'a press on the editor type with File open: its menu')
        b.p.move(ptype[2] + 26, ptype[3] + 10)
        b.btn(True)
        b.btn(False)
        its2 = b.items()
        check(not its2 and not menu_at(b.p.image(), pbox), f'its own type pressed again: closed ({len(its2)} entries)')
        # the header's View: a context menu at the pointer, on the release
        pv = [r for r in rows if r[0] == 'button' and r[1] == 'View'][0]
        pd = port_dump('--move', f'{pv[2] + 30},{pv[3] + 10}', '--press', f'{pv[2] + 30},{pv[3] + 10}')
        p_after_press = len([r for r in pd if r[0] == 'menuitem'])
        po = [r for r in port_dump('--click', f'{pv[2] + 30},{pv[3] + 10}') if r[0] == 'menuitem']
        check(p_after_press == 0, f'the header\'s View: nothing on the press ({p_after_press} entries)')
        prel = (po[0][2] - (pv[2] + 30), po[0][3] - (pv[3] + 10)) if po else None
        check(prel is not None and abs(prel[0]) <= 8 and abs(prel[1]) <= 40, f'the header\'s View on the release: at the pointer ({prel})')
    finally:
        b.close()


def main():
    try:
        for g in (g_bar, g_grey, g_outliner, g_viewport, g_small, g_recent, g_pass):
            if want(g.__name__[2:]):
                try:
                    g()
                except Exception as e:  # noqa
                    import traceback
                    traceback.print_exc()
                    check(False, f'{g.__name__}: ran to its end ({e})')
    finally:
        kill_held()
        check(_real_config() == _REAL0, 'the user\'s ~/.config/beemodel{,-zig} untouched')
        shutil.rmtree(T, True)
    print(f'menus_wl: fails {len(FAILS)}')


if __name__ == '__main__':
    main()
