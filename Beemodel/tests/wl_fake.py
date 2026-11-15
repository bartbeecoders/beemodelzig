#!/usr/bin/env python3
"""A small fake Wayland compositor for the protocol tests (tests/wl.py): just
enough of the core and of the optional globals to drive the real window code
with no desktop. Frames come out of the shared memory; nothing is displayed."""
import mmap, os, select, socket, struct, subprocess, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

CORE = [('wl_compositor', 4), ('wl_shm', 1), ('xdg_wm_base', 2), ('wl_seat', 5)]
EXTRA = [('wp_cursor_shape_manager_v1', 1), ('wp_fractional_scale_manager_v1', 1),
         ('wp_viewporter', 1), ('wl_data_device_manager', 3)]


def wstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<I', len(b)) + b + b'\0' * (-len(b) % 4)


class Toplevel:
    def __init__(self, surface, xdg, obj):
        self.surface, self.xdg, self.obj = surface, xdg, obj
        self.title = ''


class Fake:
    def __init__(self, binary, globals_=CORE + EXTRA, size=(1000, 700), env=None, args=()):
        self.dir = tempfile.mkdtemp(prefix='bmzwl')
        self.path = os.path.join(self.dir, 'wl')
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(1)
        self.globals = globals_
        self.size = size
        # (XDG_CACHE_HOME too: else the autosaves land in the user's real cache)
        e = dict(os.environ, WAYLAND_DISPLAY=self.path, HOME=self.dir, XDG_RUNTIME_DIR=self.dir,
                 XDG_CACHE_HOME=os.path.join(self.dir, 'cache'), BEEMODEL_WELCOME='0')
        e.update(env or {})
        # never the user's real home: a window run there loads and rewrites
        # ~/.config/beemodel-zig/prefs (seen twice from a caller's env)
        import pwd
        real = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
        h = os.path.realpath(e.get('HOME') or '/')
        if h == real or not h.startswith('/tmp/'):
            raise RuntimeError(f'wl_fake: refusing to start {binary} with HOME={e.get("HOME")!r} (not a temp dir)')
        self.proc = subprocess.Popen([binary, *args], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        srv.settimeout(10)
        self.c, _ = srv.accept()
        srv.close()
        self.c.setblocking(False)
        self.buf = b''
        self.fds = []
        self.types = {1: 'wl_display'}
        self.pools = {}
        self.buffers = {}
        self.surfaces = {}   # id -> dict(pending buffer, frames, dest)
        self.tops = []
        self.names = {}
        self.serial = 100
        self.frames = 0
        self.commits = []    # (surface, w, h, dest)
        self.selection_source = None
        self.source_mimes = {}
        self.device = None
        self.pointer = None
        self.keyboard = None
        self.fscale = {}     # surface -> wp_fractional_scale id
        self.next_server_id = 0xff000000
        self.errors = []
        self.locked = None    # play mode: the locked pointer, its relative motion
        self.relptr = None
        self.locks = 0
        self.cursor_hidden = False

    # --- the wire -------------------------------------------------------------
    def send(self, obj, op, payload=b'', fds=()):
        m = struct.pack('<II', obj, ((8 + len(payload)) << 16) | op) + payload
        anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack('%di' % len(fds), *fds))] if fds else []
        self.c.setblocking(True)
        self.c.sendmsg([m], anc)
        self.c.setblocking(False)

    def pump(self, secs=0.05):
        end = time.time() + secs
        while True:
            r, _, _ = select.select([self.c], [], [], max(0, end - time.time()))
            if r:
                try:
                    data, anc, _, _ = self.c.recvmsg(1 << 16, socket.CMSG_SPACE(64))
                except BlockingIOError:
                    data = None
                if data == b'':
                    return False
                if data:
                    self.buf += data
                    for lvl, typ, cd in anc:
                        if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
                            self.fds += list(struct.unpack('%di' % (len(cd) // 4), cd))
                    self.parse()
            if time.time() >= end:
                return True

    def until(self, cond, secs=5):
        end = time.time() + secs
        while time.time() < end:
            if cond():
                return True
            if not self.pump(0.02):
                return cond()
        return cond()

    def parse(self):
        while len(self.buf) >= 8:
            obj, so = struct.unpack('<II', self.buf[:8])
            size = so >> 16
            if size < 8 or len(self.buf) < size:
                return
            self.request(obj, so & 0xffff, self.buf[8:size])
            self.buf = self.buf[size:]

    def pop_fd(self):
        return self.fds.pop(0)

    # --- requests ---------------------------------------------------------------
    def request(self, obj, op, d):
        t = self.types.get(obj, '?')
        u = lambda k: struct.unpack_from('<I', d, k)[0]
        if t == 'wl_display':
            if op == 1:
                self.types[u(0)] = 'wl_registry'
                for i, (nm, ver) in enumerate(self.globals):
                    self.send(u(0), 0, struct.pack('<I', i + 1) + wstr(nm) + struct.pack('<I', ver))
            elif op == 0:
                self.send(u(0), 0, struct.pack('<I', 0))
        elif t == 'wl_registry':
            n = u(0)
            sl = u(4)
            pad = (sl + 3) & ~3
            ver = u(8 + pad)
            nid = u(12 + pad)
            nm = self.globals[n - 1][0]
            self.types[nid] = nm
            self.names[nm] = nid
            if nm == 'wl_seat':
                self.send(nid, 0, struct.pack('<I', 3))
            if nm == 'wl_shm':
                self.send(nid, 0, struct.pack('<I', 1))
        elif t == 'wl_compositor':
            if op == 0:
                self.types[u(0)] = 'wl_surface'
                self.surfaces[u(0)] = dict(buffer=None, frame=[], dest=None, last=None)
            elif op == 1:
                self.types[u(0)] = 'wl_region'
        elif t == 'wl_shm':
            if op == 0:
                self.types[u(0)] = 'wl_shm_pool'
                self.pools[u(0)] = [self.pop_fd(), u(4)]
        elif t == 'wl_shm_pool':
            if op == 0:
                a = struct.unpack_from('<IIiiiI', d)
                self.types[a[0]] = 'wl_buffer'
                self.buffers[a[0]] = dict(pool=obj, off=a[1], w=a[2], h=a[3], stride=a[4])
            elif op == 2:
                self.pools[obj][1] = u(0)
        elif t == 'wl_surface':
            s = self.surfaces[obj]
            if op == 1:
                s['buffer'] = u(0)
            elif op == 3:
                s['frame'].append(u(0))
            elif op == 6:
                self.commit(obj)
        elif t == 'xdg_wm_base':
            if op == 2:
                self.types[u(0)] = 'xdg_surface'
                self.surfaces[u(4)]['xdg'] = u(0)
        elif t == 'xdg_surface':
            if op == 1:
                self.types[u(0)] = 'xdg_toplevel'
                sf = [k for k, v in self.surfaces.items() if v.get('xdg') == obj][0]
                self.tops.append(Toplevel(sf, obj, u(0)))
        elif t == 'xdg_toplevel':
            top = [x for x in self.tops if x.obj == obj]
            if op == 2 and top:
                top[0].title = d[4:4 + u(0) - 1].decode()
            if op == 0 and top:
                self.tops.remove(top[0])
        elif t == 'wl_seat':
            if op == 0:
                self.types[u(0)] = 'wl_pointer'
                self.pointer = u(0)
            elif op == 1:
                self.types[u(0)] = 'wl_keyboard'
                self.keyboard = u(0)
        elif t == 'wp_cursor_shape_manager_v1':
            if op == 1:
                self.types[u(0)] = 'wp_cursor_shape_device_v1'
        elif t == 'wp_fractional_scale_manager_v1':
            if op == 1:
                self.types[u(0)] = 'wp_fractional_scale_v1'
                self.fscale[u(4)] = u(0)
        elif t == 'wp_viewporter':
            if op == 1:
                self.types[u(0)] = 'wp_viewport'
                self.surfaces[u(4)]['viewport'] = u(0)
        elif t == 'wp_viewport':
            if op == 2:
                sf = [k for k, v in self.surfaces.items() if v.get('viewport') == obj][0]
                self.surfaces[sf]['dest'] = struct.unpack_from('<ii', d)
        elif t == 'zwp_pointer_constraints_v1':
            if op == 1:  # lock_pointer(id, surface, pointer, region, lifetime)
                self.types[u(0)] = 'zwp_locked_pointer_v1'
                self.locked = u(0)
                self.locks += 1
                self.send(u(0), 0)                       # locked
        elif t == 'zwp_locked_pointer_v1':
            if op == 0:                                  # destroy
                self.locked = None
        elif t == 'zwp_relative_pointer_manager_v1':
            if op == 1:
                self.types[u(0)] = 'zwp_relative_pointer_v1'
                self.relptr = u(0)
        elif t == 'zwp_relative_pointer_v1':
            if op == 0:
                self.relptr = None
        elif t == 'wl_pointer':
            if op == 0:                                  # set_cursor(serial, surface, x, y)
                self.cursor_hidden = u(4) == 0
        elif t == 'wp_cursor_shape_device_v1':
            if op == 1:
                self.cursor_hidden = False
        elif t == 'wl_data_device_manager':
            if op == 0:
                self.types[u(0)] = 'wl_data_source'
                self.source_mimes[u(0)] = []
            elif op == 1:
                self.types[u(0)] = 'wl_data_device'
                self.device = u(0)
        elif t == 'wl_data_source':
            if op == 0:
                self.source_mimes[obj].append(d[4:4 + u(0) - 1].decode())
        elif t == 'wl_data_device':
            if op == 1:
                self.selection_source = u(0)
        elif t == 'wl_data_offer':
            if op == 1:  # receive(mime, fd)
                fd = self.pop_fd()
                os.write(fd, self.offer_text.encode())
                os.close(fd)
                self.received = d[4:4 + u(0) - 1].decode()

    def commit(self, sf):
        s = self.surfaces[sf]
        b = s['buffer']
        if b is None:
            # the first commit: it asks for a configure
            top = [x for x in self.tops if x.surface == sf]
            if top and not s.get('configured'):
                s['configured'] = True
                self.configure(top[0])
            return
        bf = self.buffers[b]
        s['last'] = b
        self.frames += 1
        self.commits.append((sf, bf['w'], bf['h'], s['dest']))
        s['pixels'] = self.read(bf)
        for cb in s['frame']:
            self.send(cb, 0, struct.pack('<I', 0))
        s['frame'] = []
        s['buffer'] = None
        self.send(b, 0)   # release

    def read(self, bf):
        fd, size = self.pools[bf['pool']]
        m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
        data = m[bf['off']:bf['off'] + bf['h'] * bf['stride']]
        m.close()
        return data

    def configure(self, top, size=None):
        w, h = size or self.size
        self.send(top.obj, 0, struct.pack('<iiI', w, h, 0))
        self.serial += 1
        self.send(top.xdg, 0, struct.pack('<I', self.serial))

    # --- what the compositor does -------------------------------------------------
    def main(self):
        return self.tops[0]

    def rel(self, dx, dy):
        """relative pointer motion (a locked pointer: play mode), in pixels"""
        if self.relptr:
            f = lambda v: int(v * 256)
            self.send(self.relptr, 0, struct.pack('<IIiiii', 0, 0, f(dx), f(dy), f(dx), f(dy)))

    def preferred_scale(self, s120, sf=None):
        self.send(self.fscale[sf or self.main().surface], 0, struct.pack('<I', s120))

    def enter(self, x, y, sf=None):
        self.serial += 1
        self.send(self.keyboard, 1, struct.pack('<II', self.serial, sf or self.main().surface) + struct.pack('<I', 0))
        self.serial += 1
        self.send(self.pointer, 0, struct.pack('<IIii', self.serial, sf or self.main().surface, x * 256, y * 256))

    def leave(self, sf=None):
        self.serial += 1
        self.send(self.pointer, 1, struct.pack('<II', self.serial, sf or self.main().surface))

    def motion(self, x, y):
        self.send(self.pointer, 2, struct.pack('<Iii', 1, x * 256, y * 256))

    def button(self, b=0x110, pressed=True):
        self.serial += 1
        self.send(self.pointer, 3, struct.pack('<IIII', self.serial, 1, b, 1 if pressed else 0))

    def click(self, x, y, b=0x110):
        self.motion(x, y)
        self.pump(0.02)
        self.button(b, True)
        self.pump(0.02)
        self.button(b, False)
        self.pump(0.05)

    def mods(self, m):
        self.serial += 1
        self.send(self.keyboard, 4, struct.pack('<IIIII', self.serial, m, 0, 0, 0))

    def key(self, code, mods=0):
        if mods:
            self.mods(mods)
        self.serial += 1
        self.send(self.keyboard, 3, struct.pack('<IIII', self.serial, 1, code, 1))
        self.serial += 1
        self.send(self.keyboard, 3, struct.pack('<IIII', self.serial, 1, code, 0))
        if mods:
            self.mods(0)
        self.pump(0.05)

    def offer_selection(self, text, mimes=('text/plain;charset=utf-8', 'text/plain')):
        o = self.next_server_id
        self.next_server_id += 1
        self.types[o] = 'wl_data_offer'
        self.offer_text = text
        self.send(self.device, 0, struct.pack('<I', o))
        for m in mimes:
            self.send(o, 0, wstr(m))
        self.send(self.device, 5, struct.pack('<I', o))
        self.pump(0.05)

    def ask_source(self, mime='text/plain;charset=utf-8'):
        """Another program pastes: the text our client's source writes."""
        r, w = os.pipe()
        self.send(self.selection_source, 1, wstr(mime), fds=[w])
        os.close(w)
        out = b''
        end = time.time() + 2
        os.set_blocking(r, False)
        while time.time() < end:
            self.pump(0.02)
            try:
                d = os.read(r, 65536)
            except BlockingIOError:
                continue
            if not d:
                break
            out += d
        os.close(r)
        return out

    def close(self):
        self.proc.kill()
        err = self.proc.stderr.read().decode(errors='replace')
        self.proc.wait()
        self.c.close()
        return err
