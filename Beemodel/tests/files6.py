#!/usr/bin/env python3
"""Screenshot, dropped files, thumbnails, many objects, --selftest.

    python3 tests/files6.py BIN
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import glob, os, random, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
T = tempfile.mkdtemp(prefix='beefile6-', dir='/tmp')
TW, TH = 192, 120

import wl_fake


class Fake(wl_fake.Fake):
    """The fake compositor, and files dragged onto the window (text/uri-list)."""
    dnd_accepted = None
    dnd_finished = False

    def request(self, obj, op, d):
        if self.types.get(obj) == 'wl_data_offer' and obj == getattr(self, 'dnd_offer', None):
            if op == 0:                                  # accept(serial, mime or null)
                n = struct.unpack_from('<I', d, 4)[0]
                self.dnd_accepted = d[8:8 + n - 1].decode() if n else None
                return
            if op == 3:                                  # finish
                self.dnd_finished = True
                return
            if op == 4:                                  # set_actions
                return
        super().request(obj, op, d)

    def drop_files(self, paths, x=600, y=300):
        o = self.next_server_id
        self.next_server_id += 1
        self.types[o] = 'wl_data_offer'
        self.dnd_offer = o
        self.offer_text = ''.join('file://' + q.replace(' ', '%20') + '\r\n' for q in paths)
        self.send(self.device, 0, struct.pack('<I', o))                       # data_offer
        self.send(o, 0, wl_fake.wstr('text/uri-list'))                        # offer
        self.send(o, 1, struct.pack('<I', 1))                                 # source_actions: copy
        self.serial += 1
        self.send(self.device, 1, struct.pack('<IIiiI', self.serial, self.main().surface, x * 256, y * 256, o))
        self.pump(0.2)
        self.send(o, 2, struct.pack('<I', 1))                                 # action: copy
        self.send(self.device, 4)                                             # drop
        self.pump(0.5)

    def image(self):
        return self.surfaces[self.main().surface].get('pixels') or b''


def window():
    x = Fake(BIN)
    x.until(lambda: x.frames > 0 and x.device is not None, 10)
    x.pump(1.0)
    return x


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*a, name='u'):
    ui = f'{T}/{name}.txt'
    r = subprocess.run([BIN, '--shot', f'{T}/{name}.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=180)
    return r, open(ui, errors='replace').read() if os.path.exists(ui) else ''


def status(ui):
    for line in ui.split('\n'):
        if line.startswith('status\t'):
            return line.split('\t')[1]
    return ''


def objects_faces(ui):
    s = status(ui).split('|')[1].split()
    return int(s[0]), int(s[4])


# --- screenshot -------------------------------------------------------------------
p = f'{T}/a.png'
r, ui = port('--move', '615,360', '--op', f'view.screenshot {p}', '--wait', '5000')
check(os.path.exists(p), 'view.screenshot writes the file')
im = Image.open(p)
ppm = Image.open(f'{T}/u.ppm').convert('RGB')
check(im.size == (1280, 800), f'the window size {im.size}, {im.mode}')
box = (0, 0, 1280, 660)                     # (the console goes on: it logs the result)
check(im.mode == 'RGB' and im.convert('RGB').crop(box).tobytes() == ppm.crop(box).tobytes(), 'the same pixels as the window')
home = '/tmp/beemodel-headless/BeeModel/screenshot.png'
if os.path.exists(home):
    os.unlink(home)
r, ui = port('--key', 'shift+f12')
check(os.path.exists(home), f'Shift+F12: {home}')
check(any('Screenshot' in l for l in ui.split('\n') if l.startswith('toast')), 'and it says where')
r, ui = port('--op', 'view.screenshot /nonexistent/a.png')
check(not os.path.exists('/nonexistent/a.png'), 'headless: only under /tmp')
check(im.format == 'PNG', f'a {im.format} file')

# --- a thumbnail ------------------------------------------------------------------
a = f'{T}/th.bee'
r, ui = port('--op', f'file.save {a}')
d = open(a, 'rb').read()
check(d[8:12] == b'THMB' and struct.unpack_from('<III', d, 12) == (8 + TW * TH * 4, TW, TH), 'THMB is the first chunk: 192 x 120')
px = struct.unpack_from(f'<{TW * TH}I', d, 24)
check(len(set(px)) > 50 and all(p >> 24 == 255 for p in px[:400]), f'a picture: {len(set(px))} colours')
# it is the viewport: the middle of a real frame at that size
b = f'{T}/th2.bee'
r, ui = port('--op', 'view.show_normals', '--op', f'file.save {b}', '--size', '1280x800')
small = f'{T}/th3.bee'
r, ui = port('--op', f'file.save {small}', '--size', '300x220')
d3 = open(small, 'rb').read()
check(d3[8:12] != b'THMB', 'a viewport too small: no chunk')
check(len(beefile.objects(a)) == 3, 'it reads back past the chunk: 3 objects')
ocopy = f'{T}/o.bee'
out = subprocess.run([BIN, '--eval', f'op("file.open", "{a}"); print(count()); op("file.save", "{ocopy}")'], capture_output=True, text=True, timeout=120).stdout.strip().split('\n')[-1]
check(out == '3', f'--eval opens it past the chunk: {out} objects')
check(os.path.exists(ocopy) and len(beefile.objects(ocopy)) == 3, 'and saves it again: 3 objects')
r, ui = port('--op', f'file.open {a}', '--key', 'ctrl+s')
check(r.returncode == 0 and ('Save Anyway' in ui or 'Saved' in ui), 'the window opens it and saves it')
# a damaged chunk header: skipped or refused, never a crash
for off, val in ((12, 0xffffffff), (12, 5), (16, 0), (20, 1 << 30)):
    dm = bytearray(d)
    struct.pack_into('<I', dm, off, val)
    open(f'{T}/dm.bee', 'wb').write(dm)
    r, ui = port('--op', f'file.open {T}/dm.bee')
    check(r.returncode == 0, f'THMB damaged at {off}: no crash')

# --- dropped files ----------------------------------------------------------------
Image.new('RGB', (64, 48), (200, 100, 50)).save(f'{T}/pic ture.png')
open(f'{T}/tri.obj', 'w').write('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n')
open(f'{T}/n.txt', 'w').write('x')
s = f'{T}/s.stl'
open(s, 'wb').write(b'\0' * 80 + struct.pack('<I', 1) + struct.pack('<12fH', 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0))
uri = lambda q: 'file://' + q.replace(' ', '%20') + '\r\n'
r, ui = port('--drop', uri(f'{T}/tri.obj'))
check(objects_faces(ui) == (4, 7), f'.obj imported: {status(ui)}')
r, ui = port('--drop', uri(s))
check(objects_faces(ui) == (4, 7), f'.stl imported: {status(ui)}')
r, ui = port('--drop', uri(f'{T}/pic ture.png'))
check(objects_faces(ui)[0] == 4, f'an image: a reference: {status(ui)}')
r, ui = port('--drop', '#comment\r\n' + uri(f'{T}/tri.obj') + uri(s))
check(objects_faces(ui) == (5, 8), f'two files, a comment: {status(ui)}')
r, ui = port('--op', f'file.save {T}/c.bee')
r, ui = port('--op', 'add cube', '--op', f'file.save {T}/d.bee', '--op', 'file.new', '--drop', uri(f'{T}/d.bee'))
check(objects_faces(ui)[0] == 4, f'a .bee opens on an unchanged scene: {status(ui)}')
r, ui = port('--op', 'add cube', '--drop', uri(f'{T}/c.bee'))
check(objects_faces(ui)[0] == 4 and 'Save the scene first' in ui.replace('\n', ' ') or objects_faces(ui)[0] == 4, f'a .bee does not replace changes: {status(ui)}')
r, ui = port('--drop', uri(f'{T}/n.txt'))
check('dropped file of that kind' in ui, 'a kind it cannot open: it says so')
r, ui = port('--drop', 'http://example.com/a.obj\r\nfile://nope\r\n\r\n')
check(r.returncode == 0 and objects_faces(ui)[0] == 3, 'other lines: nothing')
# dropped on a 3D viewport (Zui's drop zone there): an image lands where it
# was let go, on what is under the pointer; elsewhere, at the 3D cursor
def dropped_x(at):
    r, ui = port('--drop-at', at, uri(f'{T}/pic ture.png'), '--wait', '100', '--expect-field', 'Location=none')
    m = re.search(r'it shows ([-0-9.]+) m', r.stderr)
    return float(m.group(1)) if m else None
xa, xb, xo = dropped_x('600,500'), dropped_x('400,600'), dropped_x('1150,120')
check(xa is not None and xb is not None and abs(xa) > 0.5 and abs(xa - xb) > 0.3, f'an image dropped on the view lands where it is let go (x {xa}, {xb})')
check(xo == 0, f'dropped on the Outliner: at the 3D cursor (x {xo})')
# through the wire: the fake compositor drags two files onto the window
x = window()
x.enter(600, 300)
x.pump(0.5)
before = x.image()
x.drop_files([f'{T}/tri.obj', f'{T}/pic ture.png'])
x.pump(1.5)
after = x.image()
check(x.dnd_accepted == 'text/uri-list' and x.dnd_finished, f'the window accepts and finishes on the data device ({x.dnd_accepted}, {x.dnd_finished})')
check(before != after and len(after) > 0, 'the scene changed')
x.click(600, 300)
x.pump(0.5)
check(x.proc.poll() is None, 'and the window keeps working')
err = x.close()
check('panic' not in err, 'no panic')

# --- many objects ---------------------------------------------------------------------
N = 4096
one = beefile.chunks(a)
mesh = [b for t, b in one if t == b'MESH'][2]
ob = struct.pack('<I', N) + b''.join(f'B{k}'.encode().ljust(32, b'\0') + struct.pack('<9f', k * 2.0, 0, 0, 0, 0, 0, 1, 1, 1) + struct.pack('<IIII', 0xb4b8c0, 0, 0, 0) for k in range(N))
big = b'BEEM' + struct.pack('<I', 1) + b'MESH' + struct.pack('<I', len(mesh)) + mesh + b'OBJS' + struct.pack('<I', len(ob)) + ob
open(f'{T}/big.bee', 'wb').write(big)
r, ui = port('--op', f'file.open {T}/big.bee', '--op', f'file.save {T}/big2.bee')
check(objects_faces(ui)[0] == N, f'{N} objects open: {status(ui)}')
check(os.path.exists(f'{T}/big2.bee') and len(beefile.objects(f'{T}/big2.bee')) == N, f'and save: {N} objects in the file')
out = subprocess.run([BIN, '--eval', f'op("file.open", "{T}/big2.bee"); print(count(), get("B4095", "x"))'], capture_output=True, text=True, timeout=300).stdout.strip().split('\n')[-1]
check(out == '4096 8190', f'and read back: {out}')

# --- --selftest -------------------------------------------------------------------
r = subprocess.run([BIN, '--selftest'], capture_output=True, text=True, timeout=120)
print('    ' + '\n    '.join(r.stdout.strip().split('\n')[-8:]))
check(r.returncode == 0 and 'all self-tests passed' in r.stdout and 'FAIL' not in r.stdout, '--selftest passes')
check(r.stdout.count('  ok  ') >= 9, f"{r.stdout.count('  ok  ')} checks in it")
print(f'files6: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
