// A minimal Wayland client written against the wire protocol: no libwayland,
// no libc. Talks to the compositor over its UNIX socket with raw syscalls.
// Supports wl_compositor, wl_shm, xdg_wm_base, wl_seat (pointer + keyboard)
// and wp_cursor_shape_manager_v1 (when the compositor has it).
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wlext = @import("wlext.zig");

pub const Input = union(enum) {
    motion: struct { x: f32, y: f32 },
    leave,
    button: struct { button: u32, pressed: bool },
    wheel: f32, // steps, positive = scroll down
    key: struct { key: u32, pressed: bool },
    mods: u32,
    resize,
    close,
    focus: bool,
    /// A pen's frame begins (tablet.zig): what follows is the pen's, until pen_end.
    pen: struct { pressure: f32, eraser: bool },
    pen_end,
};

pub const Cursor = enum(u32) {
    default = 1,
    pointer = 4,
    crosshair = 8,
    text = 9,
    move = 13,
    not_allowed = 15,
    grab = 16,
    grabbing = 17,
    ew_resize = 26,
    ns_resize = 27,
    nesw_resize = 28,
    nwse_resize = 29,
};

/// xdg_toplevel resize edges
pub const Edge = struct {
    pub const top = 1;
    pub const bottom = 2;
    pub const left = 4;
    pub const right = 8;
};

pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;

pub const MOD_SHIFT = 1;
pub const MOD_CAPS = 2;
pub const MOD_CTRL = 4;
pub const MOD_ALT = 8;

const slot_default = 3840 * 2160 * 4;

pub const Window = struct {
    fd: i32 = -1,
    out: [16384]u8 = undefined,
    olen: usize = 0,
    ofds: [4]i32 = undefined,
    onfd: usize = 0,
    in: [65536]u8 = undefined,
    ilen: usize = 0,
    ifds: [64]i32 = undefined,
    ifd_n: usize = 0,
    next_id: u32 = 2,

    // object ids (0 = none)
    registry: u32 = 0,
    compositor: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    cursor_mgr: u32 = 0,
    cursor_dev: u32 = 0,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    pool: u32 = 0,
    sync_cb: u32 = 0,
    frame_cb: u32 = 0,
    synced: bool = false,

    // shm buffers: two slots in one pool
    mem_fd: i32 = -1,
    mem: [*]u8 = undefined,
    slot_size: usize = 0,
    slot_buf: [2]u32 = .{ 0, 0 },
    cur_slot: usize = 0,

    // window state
    width: i32 = 1280,
    height: i32 = 800,
    pend_w: i32 = 0,
    pend_h: i32 = 0,
    pend_max: bool = false,
    pend_tiled: bool = false,
    maximized: bool = false,
    tiled: bool = false,
    configured: bool = false,
    closed: bool = false,
    frame_pending: bool = false,

    // input
    enter_serial: u32 = 0,
    last_serial: u32 = 0,
    cursor: Cursor = .default,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 400,
    queue: [512]Input = undefined,
    qlen: usize = 0,

    // --- connection --------------------------------------------------

    pub fn connect(w: *Window, env: *const std.process.Environ.Map) !void {
        const rt = env.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
        const disp = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var addr = linux.sockaddr.un{ .path = @splat(0) };
        const path = if (disp.len > 0 and disp[0] == '/')
            try std.fmt.bufPrint(&addr.path, "{s}", .{disp})
        else
            try std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ rt, disp });
        if (path.len >= addr.path.len) return error.PathTooLong;
        const s = try sys(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        w.fd = @intCast(s);
        _ = try sys(linux.connect(w.fd, &addr, @sizeOf(linux.sockaddr.un)));

        w.registry = w.newId();
        w.req(1, 1, .{w.registry}); // wl_display.get_registry
        w.sync_cb = w.newId();
        w.req(1, 0, .{w.sync_cb}); // wl_display.sync
        try w.roundtrip();
        if (w.compositor == 0 or w.shm == 0 or w.wm_base == 0) return error.MissingGlobals;

        w.surface = w.newId();
        w.req(w.compositor, 0, .{w.surface});
        wlext.ready(w); // the clipboard, the fractional scale: when the compositor has them
        w.xdg_surface = w.newId();
        w.req(w.wm_base, 2, .{ w.xdg_surface, w.surface });
        w.toplevel = w.newId();
        w.req(w.xdg_surface, 1, .{w.toplevel});
        w.req(w.toplevel, 2, .{Str{ .s = "BeeModel (Zig)" }});
        w.req(w.toplevel, 3, .{Str{ .s = "beemodel-zig" }});
        w.req(w.toplevel, 8, .{ @as(u32, 640), @as(u32, 400) }); // set_min_size
        w.req(w.surface, 6, .{}); // commit
        try w.createPool(slot_default);
        while (!w.configured) {
            try w.flush();
            try w.readBlocking();
            w.dispatch();
        }
    }

    fn roundtrip(w: *Window) !void {
        while (!w.synced) {
            try w.flush();
            try w.readBlocking();
            w.dispatch();
        }
    }

    pub fn newId(w: *Window) u32 {
        const id = w.next_id;
        w.next_id += 1;
        return id;
    }

    // --- outgoing ------------------------------------------------------

    pub const Str = struct { s: []const u8 };
    pub const Fd = struct { fd: i32 };

    fn put32(w: *Window, v: u32) void {
        std.mem.writeInt(u32, w.out[w.olen..][0..4], v, .little);
        w.olen += 4;
    }

    /// Queue a request. Args: u32/i32 values, Str, Fd.
    pub fn req(w: *Window, obj: u32, op: u16, args: anytype) void {
        if (w.olen > w.out.len - 1024) w.flush() catch {};
        const start = w.olen;
        w.put32(obj);
        w.put32(0);
        inline for (args) |a| {
            const T = @TypeOf(a);
            if (T == Str) {
                w.put32(@intCast(a.s.len + 1));
                @memcpy(w.out[w.olen..][0..a.s.len], a.s);
                w.olen += a.s.len;
                w.out[w.olen] = 0;
                w.olen += 1;
                while (w.olen % 4 != 0) : (w.olen += 1) w.out[w.olen] = 0;
            } else if (T == Fd) {
                w.ofds[w.onfd] = a.fd;
                w.onfd += 1;
            } else if (T == i32) {
                w.put32(@bitCast(a));
            } else {
                w.put32(@intCast(a));
            }
        }
        const size: u32 = @intCast(w.olen - start);
        std.mem.writeInt(u32, w.out[start + 4 ..][0..4], (size << 16) | op, .little);
    }

    pub fn flush(w: *Window) !void {
        var off: usize = 0;
        while (off < w.olen) {
            var iov = [1]posix.iovec_const{.{ .base = w.out[off..].ptr, .len = w.olen - off }};
            var ctrl: [64]u8 align(8) = undefined;
            var msg = linux.msghdr_const{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            if (w.onfd > 0) {
                const clen = 16 + 4 * w.onfd;
                std.mem.writeInt(usize, ctrl[0..8], clen, .little);
                std.mem.writeInt(i32, ctrl[8..12], linux.SOL.SOCKET, .little);
                std.mem.writeInt(i32, ctrl[12..16], linux.SCM.RIGHTS, .little);
                for (w.ofds[0..w.onfd], 0..) |f, i| std.mem.writeInt(i32, ctrl[16 + 4 * i ..][0..4], f, .little);
                msg.control = &ctrl;
                msg.controllen = std.mem.alignForward(usize, clen, 8);
            }
            const rc = linux.sendmsg(w.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return error.SendFailed,
            }
            w.onfd = 0;
            off += rc;
        }
        w.olen = 0;
    }

    // --- incoming ------------------------------------------------------

    pub fn readBlocking(w: *Window) !void {
        var pfd = [1]linux.pollfd{.{ .fd = w.fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, -1);
        try w.read();
    }

    /// Read whatever is available on the socket (call after poll says so).
    pub fn read(w: *Window) !void {
        var iov = [1]posix.iovec{.{ .base = w.in[w.ilen..].ptr, .len = w.in.len - w.ilen }};
        var ctrl: [256]u8 align(8) = undefined;
        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &ctrl,
            .controllen = ctrl.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(w.fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.Disconnected;
        w.ilen += rc;
        var off: usize = 0;
        while (off + 16 <= msg.controllen) {
            const clen = std.mem.readInt(usize, ctrl[off..][0..8], .little);
            const level = std.mem.readInt(i32, ctrl[off + 8 ..][0..4], .little);
            const typ = std.mem.readInt(i32, ctrl[off + 12 ..][0..4], .little);
            if (clen < 16) break;
            if (level == linux.SOL.SOCKET and typ == linux.SCM.RIGHTS) {
                var i: usize = 16;
                while (i + 4 <= clen) : (i += 4) {
                    const f = std.mem.readInt(i32, ctrl[off + i ..][0..4], .little);
                    if (w.ifd_n < w.ifds.len) {
                        w.ifds[w.ifd_n] = f;
                        w.ifd_n += 1;
                    } else _ = linux.close(f);
                }
            }
            off += std.mem.alignForward(usize, clen, 8);
        }
    }

    pub fn popFd(w: *Window) i32 {
        if (w.ifd_n == 0) return -1;
        const f = w.ifds[0];
        std.mem.copyForwards(i32, w.ifds[0 .. w.ifd_n - 1], w.ifds[1..w.ifd_n]);
        w.ifd_n -= 1;
        return f;
    }

    pub const Rd = struct {
        d: []const u8,
        p: usize = 0,
        pub fn u(r: *Rd) u32 {
            if (r.p + 4 > r.d.len) return 0;
            const v = std.mem.readInt(u32, r.d[r.p..][0..4], .little);
            r.p += 4;
            return v;
        }
        pub fn i(r: *Rd) i32 {
            return @bitCast(r.u());
        }
        pub fn fixed(r: *Rd) f32 {
            return @as(f32, @floatFromInt(r.i())) / 256.0;
        }
        pub fn bytes(r: *Rd) []const u8 {
            const n = r.u();
            const end = @min(r.d.len, r.p + n);
            const s = r.d[r.p..end];
            r.p = @min(r.d.len, r.p + std.mem.alignForward(usize, n, 4));
            return s;
        }
        pub fn str(r: *Rd) []const u8 {
            const s = r.bytes();
            return if (s.len > 0 and s[s.len - 1] == 0) s[0 .. s.len - 1] else s;
        }
    };

    pub fn push(w: *Window, ev: Input) void {
        // A slow frame under a fast mouse fills the queue with motions. The
        // last part of it is kept for what must not be lost (a button's
        // release: without it the view holds the button for good): there a
        // motion replaces the motion before it, a wheel turn adds to it.
        if (w.qlen > 0 and w.qlen >= w.queue.len - 128) {
            const last = &w.queue[w.qlen - 1];
            if (ev == .motion and last.* == .motion) {
                last.* = ev;
                return;
            }
            if (ev == .wheel and last.* == .wheel) {
                last.wheel += ev.wheel;
                return;
            }
        }
        if (w.qlen < w.queue.len) {
            w.queue[w.qlen] = ev;
            w.qlen += 1;
        }
    }

    /// Decode every complete message in the input buffer.
    pub fn dispatch(w: *Window) void {
        var off: usize = 0;
        while (w.ilen - off >= 8) {
            const obj = std.mem.readInt(u32, w.in[off..][0..4], .little);
            const so = std.mem.readInt(u32, w.in[off + 4 ..][0..4], .little);
            const size: usize = so >> 16;
            if (size < 8 or w.ilen - off < size) break;
            var r = Rd{ .d = w.in[off + 8 .. off + size] };
            w.event(obj, @intCast(so & 0xffff), &r);
            off += size;
        }
        std.mem.copyForwards(u8, w.in[0 .. w.ilen - off], w.in[off..w.ilen]);
        w.ilen -= off;
    }

    pub fn bind(w: *Window, name: u32, iface: []const u8, ver: u32) u32 {
        const id = w.newId();
        w.req(w.registry, 0, .{ name, Str{ .s = iface }, ver, id });
        return id;
    }

    fn event(w: *Window, obj: u32, op: u16, r: *Rd) void {
        if (wlext.event(w, obj, op, r)) return;
        if (obj == 1) {
            if (op == 0) { // error
                const o = r.u();
                const code = r.u();
                std.debug.print("wayland error: object {d} code {d}: {s}\n", .{ o, code, r.str() });
                w.closed = true;
            }
        } else if (obj == w.registry) {
            if (op != 0) return;
            const name = r.u();
            const iface = r.str();
            const ver = r.u();
            if (std.mem.eql(u8, iface, "wl_compositor") and w.compositor == 0) {
                w.compositor = w.bind(name, iface, @min(ver, 4));
            } else if (std.mem.eql(u8, iface, "wl_shm") and w.shm == 0) {
                w.shm = w.bind(name, iface, 1);
            } else if (std.mem.eql(u8, iface, "xdg_wm_base") and w.wm_base == 0) {
                w.wm_base = w.bind(name, iface, @min(ver, 2));
            } else if (std.mem.eql(u8, iface, "wl_seat") and w.seat == 0) {
                w.seat = w.bind(name, iface, @min(ver, 5));
            } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1") and w.cursor_mgr == 0) {
                w.cursor_mgr = w.bind(name, iface, 1);
            } else wlext.global(w, name, iface, ver);
        } else if (obj == w.sync_cb and w.sync_cb != 0) {
            w.synced = true;
        } else if (obj == w.wm_base) {
            if (op == 0) w.req(w.wm_base, 3, .{r.u()}); // ping -> pong
        } else if (obj == w.xdg_surface) {
            if (op == 0) {
                w.req(w.xdg_surface, 4, .{r.u()}); // ack_configure
                if (w.pend_w > 0 and w.pend_h > 0) {
                    w.width = w.pend_w;
                    w.height = w.pend_h;
                }
                w.maximized = w.pend_max;
                w.tiled = w.pend_tiled;
                w.configured = true;
                w.push(.resize);
            }
        } else if (obj == w.toplevel) {
            if (op == 0) {
                w.pend_w = r.i();
                w.pend_h = r.i();
                const st = r.bytes();
                w.pend_max = false;
                w.pend_tiled = false;
                var i: usize = 0;
                while (i + 4 <= st.len) : (i += 4) {
                    const s = std.mem.readInt(u32, st[i..][0..4], .little);
                    if (s == 1 or s == 2) w.pend_max = true;
                    if (s >= 5 and s <= 8) w.pend_tiled = true;
                }
            } else if (op == 1) {
                w.push(.close);
            }
        } else if (obj == w.frame_cb and w.frame_cb != 0) {
            w.frame_pending = false;
            w.frame_cb = 0;
        } else if (obj == w.slot_buf[0] or obj == w.slot_buf[1]) {
            if (op == 0) { // release
                const s: usize = if (obj == w.slot_buf[0]) 0 else 1;
                w.req(obj, 0, .{}); // wl_buffer.destroy
                w.slot_buf[s] = 0;
            }
        } else if (obj == w.seat) {
            if (op == 0) {
                const caps = r.u();
                if (caps & 1 != 0 and w.pointer == 0) {
                    w.pointer = w.newId();
                    w.req(w.seat, 0, .{w.pointer});
                    if (w.cursor_mgr != 0) {
                        w.cursor_dev = w.newId();
                        w.req(w.cursor_mgr, 1, .{ w.cursor_dev, w.pointer });
                    }
                }
                if (caps & 2 != 0 and w.keyboard == 0) {
                    w.keyboard = w.newId();
                    w.req(w.seat, 1, .{w.keyboard});
                }
            }
        } else if (obj == w.pointer and w.pointer != 0) {
            switch (op) {
                0 => { // enter
                    w.enter_serial = r.u();
                    _ = r.u();
                    const x = r.fixed();
                    const y = r.fixed();
                    w.applyCursor(true);
                    w.push(.{ .motion = .{ .x = x, .y = y } });
                },
                1 => w.push(.leave),
                2 => {
                    _ = r.u();
                    const x = r.fixed();
                    const y = r.fixed();
                    w.push(.{ .motion = .{ .x = x, .y = y } });
                },
                3 => {
                    w.last_serial = r.u();
                    _ = r.u();
                    const b = r.u();
                    const st = r.u();
                    w.push(.{ .button = .{ .button = b, .pressed = st == 1 } });
                },
                4 => {
                    _ = r.u();
                    const axis = r.u();
                    const v = r.fixed();
                    if (axis == 0) w.push(.{ .wheel = v / 15.0 });
                },
                else => {},
            }
        } else if (obj == w.keyboard and w.keyboard != 0) {
            switch (op) {
                0 => { // keymap: XKB text in a shared fd
                    const format = r.u();
                    const size = r.u();
                    const f = w.popFd();
                    if (f >= 0) {
                        if (format == 1 and size > 0 and size < 16 << 20) {
                            const mp = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f, 0);
                            if (linux.errno(mp) == .SUCCESS) {
                                const p: [*]const u8 = @ptrFromInt(mp);
                                _ = @import("keyboard.zig").parse(p[0 .. size - 1]);
                                _ = linux.munmap(p, size);
                            }
                        }
                        _ = linux.close(f);
                    }
                },
                1 => w.push(.{ .focus = true }),
                2 => w.push(.{ .focus = false }),
                3 => {
                    w.last_serial = r.u();
                    _ = r.u();
                    const k = r.u();
                    const st = r.u();
                    w.push(.{ .key = .{ .key = k, .pressed = st == 1 } });
                },
                4 => {
                    _ = r.u();
                    const dep = r.u();
                    const lat = r.u();
                    const lock = r.u();
                    w.push(.{ .mods = dep | lat | (lock & MOD_CAPS) });
                },
                5 => {
                    w.repeat_rate = r.i();
                    w.repeat_delay = r.i();
                },
                else => {},
            }
        }
    }

    // --- buffers -------------------------------------------------------

    fn createPool(w: *Window, slot: usize) !void {
        const f = try sys(linux.memfd_create("beemodel-zig", linux.MFD.CLOEXEC));
        w.mem_fd = @intCast(f);
        _ = try sys(linux.ftruncate(w.mem_fd, @intCast(slot * 2)));
        const p = try sys(linux.mmap(null, slot * 2, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, w.mem_fd, 0));
        w.mem = @ptrFromInt(p);
        w.slot_size = slot;
        w.pool = w.newId();
        w.req(w.shm, 0, .{ w.pool, Fd{ .fd = w.mem_fd }, @as(u32, @intCast(slot * 2)) });
    }

    fn growPool(w: *Window, slot: usize) !void {
        _ = linux.munmap(w.mem, w.slot_size * 2);
        _ = try sys(linux.ftruncate(w.mem_fd, @intCast(slot * 2)));
        const p = try sys(linux.mmap(null, slot * 2, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, w.mem_fd, 0));
        w.mem = @ptrFromInt(p);
        w.slot_size = slot;
        w.req(w.pool, 2, .{@as(u32, @intCast(slot * 2))}); // wl_shm_pool.resize
    }

    /// A free pixel buffer of width*height to draw into, or null if both are busy.
    pub fn acquire(w: *Window) ?[*]u32 {
        const need: usize = @intCast(wlext.scale.px(w.width) * wlext.scale.px(w.height) * 4);
        var s: usize = 0;
        while (s < 2 and w.slot_buf[s] != 0) s += 1;
        if (s == 2) return null;
        if (need > w.slot_size) w.growPool(need) catch return null;
        w.cur_slot = s;
        return @ptrCast(@alignCast(w.mem + s * w.slot_size));
    }

    /// Hand the buffer from acquire() to the compositor.
    pub fn present(w: *Window) void {
        const s = w.cur_slot;
        const id = w.newId();
        w.slot_buf[s] = id;
        // create_buffer(id, offset, width, height, stride, format XRGB8888 = 1)
        const bw = wlext.scale.px(w.width);
        w.req(w.pool, 0, .{ id, @as(u32, @intCast(s * w.slot_size)), bw, wlext.scale.px(w.height), bw * 4, @as(u32, 1) });
        w.req(w.surface, 1, .{ id, @as(u32, 0), @as(u32, 0) }); // attach
        wlext.beforeCommit(w);
        w.req(w.surface, 2, .{ @as(i32, 0), @as(i32, 0), w.width, w.height }); // damage
        w.frame_cb = w.newId();
        w.req(w.surface, 3, .{w.frame_cb});
        w.req(w.surface, 6, .{}); // commit
        w.frame_pending = true;
    }

    // --- requests the UI uses -----------------------------------------

    pub fn move(w: *Window) void {
        w.req(w.toplevel, 5, .{ w.seat, w.last_serial });
    }
    pub fn resize(w: *Window, edges: u32) void {
        w.req(w.toplevel, 6, .{ w.seat, w.last_serial, edges });
    }
    pub fn setMaximized(w: *Window, on: bool) void {
        w.req(w.toplevel, if (on) 9 else 10, .{});
    }
    pub fn minimize(w: *Window) void {
        w.req(w.toplevel, 13, .{});
    }
    pub fn setCursor(w: *Window, c: Cursor) void {
        if (c == w.cursor) return;
        w.cursor = c;
        w.applyCursor(false);
    }
    fn applyCursor(w: *Window, force: bool) void {
        _ = force;
        if (w.cursor_dev != 0) w.req(w.cursor_dev, 1, .{ w.enter_serial, @intFromEnum(w.cursor) });
    }
};

fn sys(rc: usize) !usize {
    if (linux.errno(rc) != .SUCCESS) return error.SyscallFailed;
    return rc;
}
