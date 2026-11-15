//! A native Wayland backend with no libc and no libwayland: the wire
//! protocol over the compositor's socket with raw Linux syscalls, the way
//! BeeModel talks to its compositor. Builds into a static binary.
//!
//! It has xdg-shell windows with shm buffers the software renderer draws
//! into directly, fractional scale (wp_fractional_scale_v1 with
//! wp_viewporter), cursor shapes (wp_cursor_shape_v1), the clipboard and
//! files dropped on the window (wl_data_device), the keyboard layout from
//! the compositor's XKB keymap (no libxkbcommon), key repeat, and an OS
//! window for each window the UI detaches (`Ui.viewports`).
//!
//!     var display: wayland.Display = undefined;
//!     try display.init(gpa, init.environ_map, .{ .title = "My tool" });
//!     defer display.deinit();
//!     ui.clipboard = display.clipboard();
//!     while (!display.close_requested) {
//!         _ = try display.wait(&ui.input, if (ui.redraw_requested) 0 else -1);
//!         const size = display.size();
//!         ui.beginFrame(.{ .width = size.width, .height = size.height, .dt = dt });
//!         display.act(ui.clientFrame("My tool", .{ .maximized = display.maximized() }));
//!         ... describe the UI ...
//!         try display.present(&ui, try ui.endFrame());
//!     }
//!
//! There is no window frame from the system: draw one with
//! `Ui.clientFrame` and pass its action to `act`.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const keymap_mod = @import("wayland/keymap.zig");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Keymap = keymap_mod.Keymap;

/// Settings for `Display.init`.
pub const Options = struct {
    title: []const u8 = "Zui",
    /// Desktop files and window rules find the app by this.
    app_id: []const u8 = "zui",
    width: u32 = 960,
    height: u32 = 640,
    min_width: u32 = 320,
    min_height: u32 = 200,
};

/// Why the backend could not start.
pub const Error = error{
    NoRuntimeDir,
    PathTooLong,
    ConnectFailed,
    /// The compositor lacks wl_compositor, wl_shm or xdg_wm_base.
    MissingGlobals,
    SendFailed,
    ReadFailed,
    Disconnected,
    OutOfMemory,
    BufferFailed,
};

const max_surfaces = 8;
const max_fds = 16;

/// A string argument of a request.
const Str = struct { s: []const u8 };
/// A file descriptor argument of a request.
const Fd = struct { fd: i32 };

/// Reads a message's arguments.
const Reader = struct {
    d: []const u8,
    p: usize = 0,
    fn u(r: *Reader) u32 {
        if (r.p + 4 > r.d.len) return 0;
        const v = std.mem.readInt(u32, r.d[r.p..][0..4], .little);
        r.p += 4;
        return v;
    }
    fn i(r: *Reader) i32 {
        return @bitCast(r.u());
    }
    fn fixed(r: *Reader) f32 {
        return @as(f32, @floatFromInt(r.i())) / 256.0;
    }
    fn bytes(r: *Reader) []const u8 {
        const n = r.u();
        const end = @min(r.d.len, r.p + n);
        const s = r.d[r.p..end];
        r.p = @min(r.d.len, r.p + std.mem.alignForward(usize, n, 4));
        return s;
    }
    fn str(r: *Reader) []const u8 {
        const s = r.bytes();
        return if (s.len > 0 and s[s.len - 1] == 0) s[0 .. s.len - 1] else s;
    }
};

/// An OS window: the main one, or one for a detached UI window.
const Surface = struct {
    /// `.none` for the main window, else the viewport it shows.
    viewport: zui.Id = .none,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    fractional: u32 = 0,
    wp_viewport: u32 = 0,
    // One memfd pool with two buffers.
    pool: u32 = 0,
    mem_fd: i32 = -1,
    mem: [*]u8 = undefined,
    pool_size: usize = 0,
    buffers: [2]struct { id: u32 = 0, w: i32 = 0, h: i32 = 0, busy: bool = false } = .{ .{}, .{} },
    // Size in compositor units, and scale in 120ths.
    width: i32 = 0,
    height: i32 = 0,
    pend_w: i32 = 0,
    pend_h: i32 = 0,
    pend_max: bool = false,
    pend_tiled: bool = false,
    pend_active: bool = false,
    maximized: bool = false,
    tiled: bool = false,
    active: bool = true,
    configured: bool = false,
    scale120: u32 = 120,
    frame_cb: u32 = 0,
    /// A present waited for the compositor; draw again when it is ready.
    missed: bool = false,
    /// The UI no longer lists it.
    seen: bool = false,

    fn px(s: *const Surface, v: i32) i32 {
        return @intCast(@divTrunc(@as(i64, v) * s.scale120 + 60, 120));
    }
};

/// The connection to the compositor and the windows on it.
pub const Display = struct {
    gpa: Allocator,
    fd: i32 = -1,
    out: [32768]u8 = undefined,
    olen: usize = 0,
    ofds: [4]i32 = undefined,
    onfd: usize = 0,
    in: [65536]u8 = undefined,
    ilen: usize = 0,
    ifds: [max_fds]i32 = undefined,
    ifd_n: usize = 0,
    next_id: u32 = 2,
    options: Options = .{},

    registry: u32 = 0,
    compositor: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    cursor_mgr: u32 = 0,
    cursor_dev: u32 = 0,
    fscale_mgr: u32 = 0,
    viewporter: u32 = 0,
    ddm: u32 = 0,
    data_device: u32 = 0,
    sync_cb: u32 = 0,
    synced: bool = false,

    surfaces: [max_surfaces]Surface = @splat(.{}),
    surface_count: usize = 0,

    /// The window was asked to close (its frame's close, or the system).
    close_requested: bool = false,
    /// Something the UI should see arrived: input, a new size or scale.
    /// Frame callbacks and buffer releases don't count.
    woke: bool = false,
    /// Where events go; set by `wait`.
    input: ?*zui.Input = null,
    /// Viewports the system closed or resized, for `present` to tell the UI.
    closed: [max_surfaces]zui.Id = undefined,
    closed_n: usize = 0,

    // Pointer and keyboard.
    pointer_surface: u32 = 0,
    enter_serial: u32 = 0,
    last_serial: u32 = 0,
    cursor: zui.Cursor = .default,
    cursor_set: bool = false,
    keymap: Keymap = .{},
    mods: u32 = 0,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 400,
    repeat_code: ?u32 = null,
    repeat_at: u64 = 0,

    // Clipboard and drops.
    source: u32 = 0,
    /// Data sources destroyed lately: a send for one of them still brings
    /// an fd, which has to be taken and closed.
    dead_sources: [8]u32 = @splat(0),
    dead_next: usize = 0,
    own_selection: bool = false,
    copied: std.ArrayList(u8) = .empty,
    pasted: std.ArrayList(u8) = .empty,
    offer_new: u32 = 0,
    offer_new_text: i32 = -1,
    offer_new_uri: bool = false,
    offer_selection: u32 = 0,
    offer_selection_text: i32 = -1,
    dnd_offer: u32 = 0,
    dnd_ok: bool = false,
    dnd_surface: u32 = 0,
    dnd_pos: zui.Vec2 = .{},

    sw: software.SoftwareRenderer,

    const text_types = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };
    const uri_list = "text/uri-list";

    /// Connects to the compositor and opens the main window.
    pub fn init(self: *Display, gpa: Allocator, env: *const std.process.Environ.Map, options: Options) Error!void {
        self.* = .{ .gpa = gpa, .options = options, .sw = .init(gpa) };
        const rt = env.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
        const name = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var addr = linux.sockaddr.un{ .path = @splat(0) };
        const path = if (name.len > 0 and name[0] == '/')
            std.fmt.bufPrint(&addr.path, "{s}", .{name}) catch return error.PathTooLong
        else
            std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ rt, name }) catch return error.PathTooLong;
        if (path.len >= addr.path.len) return error.PathTooLong;
        const s = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s) != .SUCCESS) return error.ConnectFailed;
        self.fd = @intCast(s);
        errdefer {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (linux.errno(linux.connect(self.fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;

        self.registry = self.newId();
        self.req(1, 1, .{self.registry}); // wl_display.get_registry
        try self.roundtrip();
        if (self.compositor == 0 or self.shm == 0 or self.wm_base == 0) return error.MissingGlobals;
        // The seat's capabilities arrive after binding it.
        try self.roundtrip();
        if (self.ddm != 0 and self.seat != 0) {
            self.data_device = self.newId();
            self.req(self.ddm, 1, .{ self.data_device, self.seat });
        }
        const main = try self.openSurface(.none, options.title, @intCast(options.width), @intCast(options.height));
        while (!main.configured) {
            try self.flush();
            try self.readBlocking();
            self.dispatch();
        }
    }

    /// Closes the windows and the connection.
    pub fn deinit(self: *Display) void {
        var i = self.surface_count;
        while (i > 0) {
            i -= 1;
            self.closeSurface(i);
        }
        self.flush() catch {};
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.copied.deinit(self.gpa);
        self.pasted.deinit(self.gpa);
        self.sw.deinit();
    }

    fn newId(self: *Display) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn put32(self: *Display, v: u32) void {
        std.mem.writeInt(u32, self.out[self.olen..][0..4], v, .little);
        self.olen += 4;
    }

    /// Queues a request: u32 or i32 values, `Str` and `Fd`.
    fn req(self: *Display, obj: u32, op: u16, args: anytype) void {
        // Fds go with the bytes of the next send: flush first if this
        // request's would not fit (five new surfaces in one present).
        comptime var fds: usize = 0;
        inline for (args) |a| {
            if (@TypeOf(a) == Fd) fds += 1;
        }
        if (self.olen > self.out.len - 2048 or self.onfd + fds > self.ofds.len) self.flush() catch {};
        const start = self.olen;
        self.put32(obj);
        self.put32(0);
        inline for (args) |a| {
            const T = @TypeOf(a);
            if (T == Str) {
                const n = @min(a.s.len, 1024);
                self.put32(@intCast(n + 1));
                @memcpy(self.out[self.olen..][0..n], a.s[0..n]);
                self.olen += n;
                self.out[self.olen] = 0;
                self.olen += 1;
                while (self.olen % 4 != 0) : (self.olen += 1) self.out[self.olen] = 0;
            } else if (T == Fd) {
                self.ofds[self.onfd] = a.fd;
                self.onfd += 1;
            } else if (T == i32) {
                self.put32(@bitCast(a));
            } else {
                self.put32(@intCast(a));
            }
        }
        const len: u32 = @intCast(self.olen - start);
        std.mem.writeInt(u32, self.out[start + 4 ..][0..4], (len << 16) | op, .little);
    }

    /// Sends what is queued.
    pub fn flush(self: *Display) Error!void {
        var off: usize = 0;
        while (off < self.olen) {
            var iov = [1]posix.iovec_const{.{ .base = self.out[off..].ptr, .len = self.olen - off }};
            var ctrl: [64]u8 align(8) = undefined;
            var msg = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            if (self.onfd > 0) {
                const clen = 16 + 4 * self.onfd;
                std.mem.writeInt(usize, ctrl[0..8], clen, .little);
                std.mem.writeInt(i32, ctrl[8..12], linux.SOL.SOCKET, .little);
                std.mem.writeInt(i32, ctrl[12..16], linux.SCM.RIGHTS, .little);
                for (self.ofds[0..self.onfd], 0..) |f, k| std.mem.writeInt(i32, ctrl[16 + 4 * k ..][0..4], f, .little);
                msg.control = &ctrl;
                msg.controllen = std.mem.alignForward(usize, clen, 8);
            }
            const rc = linux.sendmsg(self.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return error.SendFailed,
            }
            self.onfd = 0;
            off += rc;
        }
        self.olen = 0;
    }

    fn roundtrip(self: *Display) Error!void {
        self.synced = false;
        self.sync_cb = self.newId();
        self.req(1, 0, .{self.sync_cb}); // wl_display.sync
        while (!self.synced) {
            try self.flush();
            try self.readBlocking();
            self.dispatch();
        }
    }

    fn readBlocking(self: *Display) Error!void {
        var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, -1);
        try self.read();
    }

    fn read(self: *Display) Error!void {
        var iov = [1]posix.iovec{.{ .base = self.in[self.ilen..].ptr, .len = self.in.len - self.ilen }};
        var ctrl: [256]u8 align(8) = undefined;
        var msg = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctrl, .controllen = ctrl.len, .flags = 0 };
        const rc = linux.recvmsg(self.fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.Disconnected;
        self.ilen += rc;
        var off: usize = 0;
        while (off + 16 <= msg.controllen) {
            const clen = std.mem.readInt(usize, ctrl[off..][0..8], .little);
            const level = std.mem.readInt(i32, ctrl[off + 8 ..][0..4], .little);
            const typ = std.mem.readInt(i32, ctrl[off + 12 ..][0..4], .little);
            if (clen < 16) break;
            if (level == linux.SOL.SOCKET and typ == linux.SCM.RIGHTS) {
                var k: usize = 16;
                while (k + 4 <= clen) : (k += 4) {
                    const f = std.mem.readInt(i32, ctrl[off + k ..][0..4], .little);
                    if (self.ifd_n < self.ifds.len) {
                        self.ifds[self.ifd_n] = f;
                        self.ifd_n += 1;
                    } else _ = linux.close(f);
                }
            }
            off += std.mem.alignForward(usize, clen, 8);
        }
    }

    fn popFd(self: *Display) i32 {
        if (self.ifd_n == 0) return -1;
        const f = self.ifds[0];
        std.mem.copyForwards(i32, self.ifds[0 .. self.ifd_n - 1], self.ifds[1..self.ifd_n]);
        self.ifd_n -= 1;
        return f;
    }

    fn dispatch(self: *Display) void {
        var off: usize = 0;
        while (self.ilen - off >= 8) {
            const obj = std.mem.readInt(u32, self.in[off..][0..4], .little);
            const so = std.mem.readInt(u32, self.in[off + 4 ..][0..4], .little);
            const len: usize = so >> 16;
            if (len < 8 or self.ilen - off < len) break;
            var r: Reader = .{ .d = self.in[off + 8 .. off + len] };
            self.event(obj, @intCast(so & 0xffff), &r);
            off += len;
        }
        std.mem.copyForwards(u8, self.in[0 .. self.ilen - off], self.in[off..self.ilen]);
        self.ilen -= off;
    }

    fn bind(self: *Display, name: u32, iface: []const u8, version: u32) u32 {
        const id = self.newId();
        self.req(self.registry, 0, .{ name, Str{ .s = iface }, version, id });
        return id;
    }

    /// Waits up to `timeout_ms` (-1: until something happens) for events
    /// and feeds them into `input`. Returns true if anything arrived that
    /// the UI should see; see also `needsFrame`.
    pub fn wait(self: *Display, input: *zui.Input, timeout_ms: i32) Error!bool {
        self.input = input;
        defer self.input = null;
        try self.flush();
        var timeout = if (self.needsFrame()) 0 else timeout_ms;
        if (self.repeat_code != null) {
            const now = monotonicMs();
            const until: i32 = @intCast(@min(@as(u64, std.math.maxInt(i32)), self.repeat_at -| now));
            timeout = if (timeout < 0) until else @min(timeout, until);
        }
        var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, timeout);
        self.woke = false;
        if (linux.errno(rc) == .SUCCESS and rc > 0) {
            if (pfd[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) return error.Disconnected;
            try self.read();
            self.dispatch();
        }
        var got = self.woke;
        if (self.repeat_code) |code| {
            const now = monotonicMs();
            if (now >= self.repeat_at and self.repeat_rate > 0) {
                self.keyDown(code, true);
                self.repeat_at = now + @as(u64, @intCast(@divTrunc(1000, self.repeat_rate)));
                got = true;
            }
        }
        if (self.closed_n > 0) got = true;
        return got;
    }

    /// A frame was skipped because the compositor wasn't ready, and now it
    /// is: draw one more (without the input's settling frames).
    pub fn needsFrame(self: *const Display) bool {
        for (self.surfaces[0..self.surface_count]) |s| if (s.missed and s.frame_cb == 0 and s.configured) return true;
        return false;
    }

    /// The main window's size in compositor units, for `Ui.beginFrame`,
    /// and its scale.
    pub fn size(self: *const Display) struct { width: f32, height: f32, scale: f32 } {
        const s = &self.surfaces[0];
        return .{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height), .scale = @as(f32, @floatFromInt(s.scale120)) / 120 };
    }

    /// The main window is maximized or tiled: for `Ui.clientFrame`.
    pub fn maximized(self: *const Display) bool {
        return self.surfaces[0].maximized or self.surfaces[0].tiled;
    }

    /// The main window has the keyboard.
    pub fn active(self: *const Display) bool {
        return self.surfaces[0].active;
    }

    /// Carries out what the window frame asked for.
    pub fn act(self: *Display, action: zui.FrameAction) void {
        const s = &self.surfaces[0];
        switch (action) {
            .none => {},
            .move => self.req(s.toplevel, 5, .{ self.seat, self.last_serial }),
            .resize => |edges| self.req(s.toplevel, 6, .{ self.seat, self.last_serial, edges.xdg() }),
            .minimize => self.req(s.toplevel, 13, .{}),
            .maximize => self.req(s.toplevel, if (s.maximized) 10 else 9, .{}),
            .close => self.close_requested = true,
        }
    }

    /// The system clipboard, for `Ui.clipboard`.
    pub fn clipboard(self: *Display) zui.Clipboard {
        return .{ .context = self, .getFn = getClipboard, .setFn = setClipboard };
    }

    /// Draws the frame: the main window, an OS window for each viewport
    /// (opening and closing them as the UI asks), the pointer shape, and
    /// the eyedropper's pixel.
    pub fn present(self: *Display, ui: *zui.Ui, list: *const zui.DrawList) Error!void {
        // Viewports the system closed or that changed size.
        for (self.closed[0..self.closed_n]) |id| ui.closeViewport(id);
        self.closed_n = 0;

        const main = &self.surfaces[0];
        const frame = ui.renderFrame(@as(f32, @floatFromInt(main.scale120)) / 120);
        if (try self.draw(main, list, frame, ui.style.colors.background)) {
            if (ui.sample_request) |p| {
                const x: i32 = @intFromFloat(@floor(p.x * frame.scale));
                const y: i32 = @intFromFloat(@floor(p.y * frame.scale));
                if (self.sw.pixelAt(x, y)) |c| {
                    if (ui.input.onColorSample(c)) ui.requestRedraw();
                }
            }
        }

        // Detached windows.
        for (self.surfaces[1..self.surface_count]) |*s| s.seen = false;
        for (ui.viewports()) |vp| {
            const s = self.surfaceFor(vp.id) orelse self.openSurface(vp.id, vp.title, @intFromFloat(vp.size.x), @intFromFloat(vp.size.y)) catch continue;
            s.seen = true;
            if (s.configured and s.width > 0) {
                const w: f32 = @floatFromInt(s.width);
                const h: f32 = @floatFromInt(s.height);
                ui.setViewportSize(vp.id, .{ .x = w / ui.ui_scale, .y = h / ui.ui_scale });
            }
            switch (vp.request) {
                .none => {},
                .move => self.req(s.toplevel, 5, .{ self.seat, self.last_serial }),
                .resize => |edges| self.req(s.toplevel, 6, .{ self.seat, self.last_serial, edges.xdg() }),
            }
            const vf: zui.Frame = .{ .width = vp.size.x, .height = vp.size.y, .scale = @as(f32, @floatFromInt(s.scale120)) / 120 * ui.ui_scale };
            _ = try self.draw(s, vp.list, vf, ui.style.colors.window);
        }
        var i = self.surface_count;
        while (i > 1) {
            i -= 1;
            if (!self.surfaces[i].seen) self.closeSurface(i);
        }

        self.setCursor(ui.cursor);
        try self.flush();
    }

    fn surfaceFor(self: *Display, viewport: zui.Id) ?*Surface {
        for (self.surfaces[0..self.surface_count]) |*s| if (s.viewport == viewport) return s;
        return null;
    }

    fn surfaceById(self: *Display, id: u32) ?*Surface {
        if (id == 0) return null;
        for (self.surfaces[0..self.surface_count]) |*s| if (s.surface == id) return s;
        return null;
    }

    fn openSurface(self: *Display, viewport: zui.Id, title: []const u8, w: i32, h: i32) Error!*Surface {
        if (self.surface_count == max_surfaces) return error.OutOfMemory;
        const s = &self.surfaces[self.surface_count];
        self.surface_count += 1;
        s.* = .{ .viewport = viewport, .width = w, .height = h };
        s.surface = self.newId();
        self.req(self.compositor, 0, .{s.surface});
        if (self.fscale_mgr != 0 and self.viewporter != 0) {
            s.fractional = self.newId();
            self.req(self.fscale_mgr, 1, .{ s.fractional, s.surface });
            s.wp_viewport = self.newId();
            self.req(self.viewporter, 1, .{ s.wp_viewport, s.surface });
        }
        s.xdg_surface = self.newId();
        self.req(self.wm_base, 2, .{ s.xdg_surface, s.surface });
        s.toplevel = self.newId();
        self.req(s.xdg_surface, 1, .{s.toplevel});
        self.req(s.toplevel, 2, .{Str{ .s = title }});
        self.req(s.toplevel, 3, .{Str{ .s = self.options.app_id }});
        self.req(s.toplevel, 8, .{ self.options.min_width, self.options.min_height });
        self.req(s.surface, 6, .{}); // commit, for the first configure
        return s;
    }

    fn closeSurface(self: *Display, index: usize) void {
        const s = &self.surfaces[index];
        for (s.buffers) |b| if (b.id != 0) self.req(b.id, 0, .{});
        if (s.pool != 0) self.req(s.pool, 1, .{});
        if (s.wp_viewport != 0) self.req(s.wp_viewport, 0, .{});
        if (s.fractional != 0) self.req(s.fractional, 0, .{});
        self.req(s.toplevel, 0, .{});
        self.req(s.xdg_surface, 0, .{});
        self.req(s.surface, 0, .{});
        if (s.pool_size > 0) _ = linux.munmap(s.mem, s.pool_size);
        if (s.mem_fd >= 0) _ = linux.close(s.mem_fd);
        if (self.pointer_surface == s.surface) self.pointer_surface = 0;
        std.mem.copyForwards(Surface, self.surfaces[index .. self.surface_count - 1], self.surfaces[index + 1 .. self.surface_count]);
        self.surface_count -= 1;
    }

    /// Renders `list` into a free buffer of `s` and shows it. False if the
    /// compositor isn't ready for another one yet.
    fn draw(self: *Display, s: *Surface, list: *const zui.DrawList, frame: zui.Frame, background: zui.Color) Error!bool {
        if (!s.configured or s.width <= 0 or s.height <= 0) return false;
        if (s.frame_cb != 0) {
            s.missed = true;
            return false;
        }
        const pw = s.px(s.width);
        const ph = s.px(s.height);
        var slot: ?usize = null;
        for (s.buffers, 0..) |b, k| if (!b.busy) {
            slot = k;
            break;
        };
        const k = slot orelse {
            s.missed = true;
            return false;
        };
        s.missed = false;
        const bytes: usize = @as(usize, @intCast(pw)) * @as(usize, @intCast(ph)) * 4;
        if (bytes * 2 > s.pool_size) {
            // Growing moves the second buffer's place: wait until the
            // compositor has let go of both, rather than draw over one it
            // may still be reading.
            for (s.buffers) |other| if (other.busy) {
                s.missed = true;
                return false;
            };
            try self.growPool(s, bytes * 2);
        }
        const b = &s.buffers[k];
        if (b.id == 0 or b.w != pw or b.h != ph) {
            if (b.id != 0) self.req(b.id, 0, .{});
            b.id = self.newId();
            b.w = pw;
            b.h = ph;
            // create_buffer(id, offset, width, height, stride, XRGB8888)
            self.req(s.pool, 0, .{ b.id, @as(u32, @intCast(k * (s.pool_size / 2))), pw, ph, pw * 4, @as(u32, 1) });
        }
        const pixels: [*]u32 = @ptrCast(@alignCast(s.mem + k * (s.pool_size / 2)));
        self.sw.useBuffer(pixels[0 .. bytes / 4], @intCast(pw), @intCast(ph));
        self.sw.clear = true;
        self.sw.clear_color = background;
        var f = frame;
        f.scale = @as(f32, @floatFromInt(pw)) / @max(1, frame.width);
        self.sw.renderer().render(list, f);

        self.req(s.surface, 1, .{ b.id, @as(u32, 0), @as(u32, 0) }); // attach
        if (s.wp_viewport != 0) self.req(s.wp_viewport, 2, .{ s.width, s.height }); // set_destination
        self.req(s.surface, 9, .{ @as(i32, 0), @as(i32, 0), pw, ph }); // damage_buffer
        s.frame_cb = self.newId();
        self.req(s.surface, 3, .{s.frame_cb});
        self.req(s.surface, 6, .{}); // commit
        b.busy = true;
        return true;
    }

    fn growPool(self: *Display, s: *Surface, want: usize) Error!void {
        const need = std.mem.alignForward(usize, want + want / 4, 4096);
        if (s.mem_fd < 0) {
            const f = linux.memfd_create("zui-buffer", linux.MFD.CLOEXEC);
            if (linux.errno(f) != .SUCCESS) return error.BufferFailed;
            s.mem_fd = @intCast(f);
        } else if (s.pool_size > 0) {
            _ = linux.munmap(s.mem, s.pool_size);
            // Nothing mapped until the new mapping is made: a failure below
            // leaves no stale mapping to unmap again later.
            s.pool_size = 0;
        }
        if (linux.errno(linux.ftruncate(s.mem_fd, @intCast(need))) != .SUCCESS) return error.BufferFailed;
        const p = linux.mmap(null, need, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, s.mem_fd, 0);
        if (linux.errno(p) != .SUCCESS) return error.BufferFailed;
        s.mem = @ptrFromInt(p);
        if (s.pool == 0) {
            s.pool = self.newId();
            self.req(self.shm, 0, .{ s.pool, Fd{ .fd = s.mem_fd }, @as(u32, @intCast(need)) });
        } else {
            self.req(s.pool, 2, .{@as(u32, @intCast(need))}); // resize
            // Buffers point at offsets that moved: make them again.
            for (&s.buffers) |*b| if (b.id != 0 and !b.busy) {
                self.req(b.id, 0, .{});
                b.id = 0;
            };
        }
        s.pool_size = need;
    }

    fn setCursor(self: *Display, c: zui.Cursor) void {
        if (c == self.cursor and self.cursor_set) return;
        self.cursor = c;
        self.applyCursor();
    }

    fn applyCursor(self: *Display) void {
        if (self.cursor_dev == 0 or self.enter_serial == 0) return;
        const shape: u32 = switch (self.cursor) {
            .default => 1,
            .pointer => 4,
            .crosshair => 8,
            .text => 9,
            .move => 13,
            .not_allowed => 15,
            .grab => 16,
            .grabbing => 17,
            .resize_ew => 26,
            .resize_ns => 27,
            .resize_nesw => 28,
            .resize_nwse => 29,
        };
        self.req(self.cursor_dev, 1, .{ self.enter_serial, shape });
        self.cursor_set = true;
    }

    fn viewportOf(self: *Display, surface: u32) zui.Id {
        return if (self.surfaceById(surface)) |s| s.viewport else .none;
    }

    fn event(self: *Display, obj: u32, op: u16, r: *Reader) void {
        if (obj == 1) {
            if (op == 0) {
                const o = r.u();
                const code = r.u();
                std.log.err("wayland: object {d}, error {d}: {s}", .{ o, code, r.str() });
                self.close_requested = true;
            }
            return;
        }
        if (obj == self.registry) return self.global(op, r);
        if (obj == self.sync_cb and self.sync_cb != 0) {
            self.synced = true;
            return;
        }
        if (obj == self.wm_base) {
            if (op == 0) self.req(self.wm_base, 3, .{r.u()}); // ping, pong
            return;
        }
        if (obj == self.seat) return self.seatEvent(op, r);
        if (obj == self.pointer and obj != 0) return self.pointerEvent(op, r);
        if (obj == self.keyboard and obj != 0) return self.keyboardEvent(op, r);
        if (obj == self.data_device and obj != 0) return self.deviceEvent(op, r);
        if (obj == self.source and obj != 0) return self.sourceEvent(op, r);
        if (obj != 0 and std.mem.indexOfScalar(u32, &self.dead_sources, obj) != null) {
            // send(mime, fd) to a source we dropped: its fd is next in line.
            if (op == 1) {
                const fd = self.popFd();
                if (fd >= 0) _ = linux.close(fd);
            }
            return;
        }
        if (obj == self.offer_new and obj != 0) {
            if (op == 0) {
                const m = r.str();
                if (std.mem.eql(u8, m, uri_list)) self.offer_new_uri = true;
                for (text_types, 0..) |t, k| {
                    if (std.mem.eql(u8, m, t) and (self.offer_new_text < 0 or k < self.offer_new_text)) self.offer_new_text = @intCast(k);
                }
            }
            return;
        }
        for (self.surfaces[0..self.surface_count]) |*s| {
            if (obj == s.xdg_surface) {
                if (op == 0) {
                    self.req(s.xdg_surface, 4, .{r.u()}); // ack_configure
                    if (s.pend_w > 0 and s.pend_h > 0) {
                        s.width = s.pend_w;
                        s.height = s.pend_h;
                    }
                    s.maximized = s.pend_max;
                    s.tiled = s.pend_tiled;
                    s.active = s.pend_active;
                    s.configured = true;
                    s.missed = true;
                    self.woke = true;
                }
                return;
            }
            if (obj == s.toplevel) {
                if (op == 0) {
                    s.pend_w = r.i();
                    s.pend_h = r.i();
                    const states = r.bytes();
                    s.pend_max = false;
                    s.pend_tiled = false;
                    s.pend_active = false;
                    var k: usize = 0;
                    while (k + 4 <= states.len) : (k += 4) {
                        const st = std.mem.readInt(u32, states[k..][0..4], .little);
                        if (st == 1 or st == 2) s.pend_max = true;
                        if (st == 4) s.pend_active = true;
                        if (st >= 5 and st <= 8) s.pend_tiled = true;
                    }
                } else if (op == 1) {
                    self.woke = true;
                    if (s.viewport == .none) self.close_requested = true else if (self.closed_n < self.closed.len) {
                        self.closed[self.closed_n] = s.viewport;
                        self.closed_n += 1;
                    }
                }
                return;
            }
            if (obj == s.frame_cb and s.frame_cb != 0) {
                s.frame_cb = 0;
                return;
            }
            if (obj == s.fractional and s.fractional != 0) {
                if (op == 0) {
                    const v = r.u();
                    if (v != 0 and v != s.scale120) {
                        s.scale120 = v;
                        s.missed = true;
                        self.woke = true;
                    }
                }
                return;
            }
            for (&s.buffers) |*b| if (obj == b.id and b.id != 0) {
                if (op == 0) b.busy = false; // release
                return;
            };
        }
    }

    fn global(self: *Display, op: u16, r: *Reader) void {
        if (op != 0) return;
        const name = r.u();
        const iface = r.str();
        const version = r.u();
        const eq = std.mem.eql;
        if (eq(u8, iface, "wl_compositor") and self.compositor == 0) {
            self.compositor = self.bind(name, iface, @min(version, 4));
        } else if (eq(u8, iface, "wl_shm") and self.shm == 0) {
            self.shm = self.bind(name, iface, 1);
        } else if (eq(u8, iface, "xdg_wm_base") and self.wm_base == 0) {
            self.wm_base = self.bind(name, iface, @min(version, 2));
        } else if (eq(u8, iface, "wl_seat") and self.seat == 0) {
            self.seat = self.bind(name, iface, @min(version, 5));
        } else if (eq(u8, iface, "wp_cursor_shape_manager_v1") and self.cursor_mgr == 0) {
            self.cursor_mgr = self.bind(name, iface, 1);
        } else if (eq(u8, iface, "wp_fractional_scale_manager_v1") and self.fscale_mgr == 0) {
            self.fscale_mgr = self.bind(name, iface, 1);
        } else if (eq(u8, iface, "wp_viewporter") and self.viewporter == 0) {
            self.viewporter = self.bind(name, iface, 1);
        } else if (eq(u8, iface, "wl_data_device_manager") and self.ddm == 0) {
            self.ddm = self.bind(name, iface, @min(version, 3));
        }
    }

    fn seatEvent(self: *Display, op: u16, r: *Reader) void {
        if (op != 0) return;
        const caps = r.u();
        if (caps & 1 != 0 and self.pointer == 0) {
            self.pointer = self.newId();
            self.req(self.seat, 0, .{self.pointer});
            if (self.cursor_mgr != 0) {
                self.cursor_dev = self.newId();
                self.req(self.cursor_mgr, 1, .{ self.cursor_dev, self.pointer });
            }
        }
        if (caps & 2 != 0 and self.keyboard == 0) {
            self.keyboard = self.newId();
            self.req(self.seat, 1, .{self.keyboard});
        }
    }

    fn pointerEvent(self: *Display, op: u16, r: *Reader) void {
        const in = self.input orelse return;
        self.woke = true;
        switch (op) {
            0 => { // enter(serial, surface, x, y)
                self.enter_serial = r.u();
                self.pointer_surface = r.u();
                in.viewport = self.viewportOf(self.pointer_surface);
                const x = r.fixed();
                const y = r.fixed();
                self.cursor_set = false;
                self.applyCursor();
                in.onMouseMove(.{ .x = x, .y = y });
            },
            1 => { // leave: far away, so nothing stays hovered
                in.onMouseMove(.{ .x = -100000, .y = -100000 });
                // The compositor has the pointer now (a window move or
                // resize, another window): a button held will never be seen
                // going up, so it goes up here.
                var it = in.mouse_down.iterator();
                while (it.next()) |b| in.onMouseButton(b, false);
            },
            2 => {
                _ = r.u();
                const x = r.fixed();
                const y = r.fixed();
                in.onMouseMove(.{ .x = x, .y = y });
            },
            3 => { // button(serial, time, button, state)
                self.last_serial = r.u();
                _ = r.u();
                const b = r.u();
                const down = r.u() == 1;
                const button: ?zui.MouseButton = switch (b) {
                    0x110 => .left,
                    0x111 => .right,
                    0x112 => .middle,
                    else => null,
                };
                if (button) |btn| in.onMouseButton(btn, down);
            },
            4 => { // axis(time, axis, value): 15 per notch, down positive
                _ = r.u();
                const axis = r.u();
                const v = r.fixed() / 15;
                if (axis == 0) in.onScroll(.{ .x = 0, .y = -v }) else in.onScroll(.{ .x = -v, .y = 0 });
            },
            else => {},
        }
    }

    fn keyboardEvent(self: *Display, op: u16, r: *Reader) void {
        self.woke = true;
        switch (op) {
            0 => { // keymap(format, fd, size)
                const format = r.u();
                const sz = r.u();
                const f = self.popFd();
                if (f < 0) return;
                defer _ = linux.close(f);
                if (format != 1 or sz == 0 or sz >= 16 << 20) return;
                const mp = linux.mmap(null, sz, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f, 0);
                if (linux.errno(mp) != .SUCCESS) return;
                const p: [*]const u8 = @ptrFromInt(mp);
                _ = self.keymap.parse(p[0 .. sz - 1]);
                _ = linux.munmap(p, sz);
            },
            1 => { // enter(serial, surface, keys)
                _ = r.u();
                const surface = r.u();
                if (self.input) |in| in.keyboard_viewport = self.viewportOf(surface);
            },
            2 => { // leave: keys held now will never be seen going up
                self.repeat_code = null;
                if (self.input) |in| {
                    var it = in.keys_down.iterator();
                    while (it.next()) |k| in.onKeyRelease(k);
                }
            },
            3 => { // key(serial, time, key, state)
                self.last_serial = r.u();
                _ = r.u();
                const code = r.u();
                const down = r.u() == 1;
                if (down) {
                    self.keyDown(code, false);
                    // (a rate of 0 means the compositor wants no repeat)
                    if (!isModifier(code) and self.repeat_rate > 0) {
                        self.repeat_code = code;
                        self.repeat_at = monotonicMs() + @as(u64, @intCast(@max(0, self.repeat_delay)));
                    }
                } else {
                    if (self.repeat_code == code) self.repeat_code = null;
                    if (self.input) |in| if (self.keymap.key(code)) |k| in.onKeyRelease(k);
                }
            },
            4 => { // modifiers(serial, depressed, latched, locked, group)
                _ = r.u();
                const dep = r.u();
                const lat = r.u();
                const lock = r.u();
                self.keymap.setGroup(r.u()); // the layout in use
                self.mods = dep | lat | (lock & keymap_mod.mod_caps);
                if (self.input) |in| in.modifiers = .{
                    .shift = self.mods & keymap_mod.mod_shift != 0,
                    .ctrl = self.mods & keymap_mod.mod_ctrl != 0,
                    .alt = self.mods & keymap_mod.mod_alt != 0,
                    .super = self.mods & keymap_mod.mod_super != 0,
                };
            },
            5 => {
                self.repeat_rate = r.i();
                self.repeat_delay = r.i();
                if (self.repeat_rate <= 0) self.repeat_code = null;
            },
            else => {},
        }
    }

    fn keyDown(self: *Display, code: u32, repeat: bool) void {
        const in = self.input orelse return;
        _ = repeat;
        if (self.keymap.key(code)) |k| in.onKeyPress(k);
        // Text, unless Ctrl or Alt make it a shortcut (AltGr types).
        if (self.mods & (keymap_mod.mod_ctrl | keymap_mod.mod_alt) != 0) return;
        const cp = self.keymap.char(code, self.mods);
        if (cp < 0x20 or cp == 0x7f) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(@min(cp, 0x10ffff)), &buf) catch return;
        in.onText(buf[0..n]);
    }

    fn deviceEvent(self: *Display, op: u16, r: *Reader) void {
        self.woke = true;
        switch (op) {
            0 => { // data_offer(id): its types follow
                self.offer_new = r.u();
                self.offer_new_text = -1;
                self.offer_new_uri = false;
            },
            1 => { // enter(serial, surface, x, y, offer)
                const serial = r.u();
                self.dnd_surface = r.u();
                self.dnd_pos = .{ .x = r.fixed(), .y = r.fixed() };
                self.dnd_offer = r.u();
                self.dnd_ok = self.dnd_offer != 0 and self.dnd_offer == self.offer_new and self.offer_new_uri;
                if (self.dnd_ok) {
                    self.req(self.dnd_offer, 0, .{ serial, Str{ .s = uri_list } }); // accept
                    self.req(self.dnd_offer, 4, .{ @as(u32, 1), @as(u32, 1) }); // set_actions(copy, copy)
                }
            },
            2 => self.endDrag(), // leave
            3 => { // motion(time, x, y)
                _ = r.u();
                self.dnd_pos = .{ .x = r.fixed(), .y = r.fixed() };
            },
            4 => self.dropped(),
            5 => { // selection(offer or 0)
                const o = r.u();
                if (self.offer_selection != 0 and self.offer_selection != o and self.offer_selection != self.dnd_offer) self.req(self.offer_selection, 2, .{});
                self.offer_selection = o;
                self.offer_selection_text = if (o == self.offer_new) self.offer_new_text else -1;
                if (o != 0 and self.source == 0) self.own_selection = false;
            },
            else => {},
        }
    }

    fn endDrag(self: *Display) void {
        if (self.dnd_offer != 0 and self.dnd_offer != self.offer_selection) self.req(self.dnd_offer, 2, .{});
        self.dnd_offer = 0;
        self.dnd_ok = false;
    }

    /// Files dropped: the uri list through a pipe, one path each.
    fn dropped(self: *Display) void {
        defer self.endDrag();
        if (!self.dnd_ok) return;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        const whole = self.receive(self.dnd_offer, uri_list, &list, 1 << 20);
        self.req(self.dnd_offer, 3, .{}); // finish
        const in = self.input orelse return;
        in.viewport = self.viewportOf(self.dnd_surface);
        // Cut short: the last line may be part of a path, which could name
        // another, real file. Only whole lines.
        var got = list.items;
        if (!whole) got = got[0 .. if (std.mem.lastIndexOfScalar(u8, got, '\n')) |nl| nl + 1 else 0];
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            var path: [4096]u8 = undefined;
            if (pathOfUri(line, &path)) |p| in.onFileDrop(p, self.dnd_pos);
        }
    }

    fn retireSource(self: *Display) void {
        self.dead_sources[self.dead_next] = self.source;
        self.dead_next = (self.dead_next + 1) % self.dead_sources.len;
        self.source = 0;
    }

    fn sourceEvent(self: *Display, op: u16, r: *Reader) void {
        switch (op) {
            1 => { // send(mime, fd): write our text
                _ = r.str();
                const fd = self.popFd();
                if (fd >= 0) writeAll(fd, self.copied.items);
            },
            2 => { // cancelled: another program has the clipboard
                self.req(self.source, 1, .{});
                self.retireSource();
                self.own_selection = false;
            },
            else => {},
        }
    }

    /// Reads what an offer holds as `mime` into `out`, through a pipe: up
    /// to `cap` bytes, and for one second in all however slowly the other
    /// program writes. True if it got everything (the writer closed the pipe).
    fn receive(self: *Display, offer: u32, mime: []const u8, out: *std.ArrayList(u8), cap: usize) bool {
        out.clearRetainingCapacity();
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return false;
        self.req(offer, 1, .{ Str{ .s = mime }, Fd{ .fd = fds[1] } });
        self.flush() catch {};
        _ = linux.close(fds[1]);
        defer _ = linux.close(fds[0]);
        const deadline = monotonicMs() + 1000;
        while (out.items.len < cap) {
            const now = monotonicMs();
            if (now >= deadline) return false;
            var p = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
            const pr = linux.poll(&p, 1, @intCast(deadline - now));
            if (linux.errno(pr) == .INTR) continue;
            if (linux.errno(pr) != .SUCCESS or pr == 0) return false;
            out.ensureUnusedCapacity(self.gpa, @min(64 << 10, cap - out.items.len)) catch return false;
            const room = out.unusedCapacitySlice()[0..@min(out.unusedCapacitySlice().len, cap - out.items.len)];
            const rc = linux.read(fds[0], room.ptr, room.len);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return false;
            if (rc == 0) return true;
            out.items.len += rc;
        }
        return false;
    }

    fn getClipboard(context: *anyopaque) []const u8 {
        const self: *Display = @ptrCast(@alignCast(context));
        if (self.own_selection) return self.copied.items;
        if (self.offer_selection == 0 or self.offer_selection_text < 0) return "";
        const whole = self.receive(self.offer_selection, text_types[@intCast(self.offer_selection_text)], &self.pasted, 16 << 20);
        // Cut short (too big, too slow): never in the middle of a character.
        if (!whole) self.pasted.items.len = wholeUtf8(self.pasted.items);
        return self.pasted.items;
    }

    fn setClipboard(context: *anyopaque, text: []const u8) void {
        const self: *Display = @ptrCast(@alignCast(context));
        self.copied.clearRetainingCapacity();
        self.copied.appendSlice(self.gpa, text) catch return;
        self.own_selection = true;
        if (self.ddm == 0 or self.data_device == 0) return;
        if (self.source != 0) {
            self.req(self.source, 1, .{});
            self.retireSource();
        }
        self.source = self.newId();
        self.req(self.ddm, 0, .{self.source}); // create_data_source
        for (text_types) |m| self.req(self.source, 0, .{Str{ .s = m }});
        self.req(self.data_device, 1, .{ self.source, self.last_serial }); // set_selection
        self.flush() catch {};
    }
};

fn isModifier(code: u32) bool {
    return switch (code) {
        29, 97, 42, 54, 56, 100, 125, 126, 58 => true,
        else => false,
    };
}

fn monotonicMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Writes all of `bytes` to `fd` and closes it; a reader that went away
/// is no signal.
/// The length of `bytes` without a character cut off at its end.
fn wholeUtf8(bytes: []const u8) usize {
    var i = bytes.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        if (bytes[i] & 0xC0 != 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
            return if (i + len <= bytes.len) bytes.len else i;
        }
    }
    return bytes.len;
}

test "wholeUtf8 drops a character cut off at the end" {
    try std.testing.expectEqual(@as(usize, 3), wholeUtf8("abc"));
    try std.testing.expectEqual(@as(usize, 1), wholeUtf8("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), wholeUtf8("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), wholeUtf8("a\xe6\x97"));
}

fn writeAll(fd: i32, bytes: []const u8) void {
    defer _ = linux.close(fd);
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, fl | 0o4000); // O_NONBLOCK
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            .AGAIN => {
                var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                if (linux.poll(&p, 1, 1000) == 0) break;
            },
            else => break,
        }
    }
}

/// The path of a `file://` line of a uri list, %XX decoded; null for
/// comments and other kinds.
pub fn pathOfUri(line0: []const u8, out: []u8) ?[]const u8 {
    const line = std.mem.trim(u8, line0, "\r\n ");
    if (line.len == 0 or line[0] == '#' or !std.mem.startsWith(u8, line, "file://")) return null;
    const rest = line[7..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const p = rest[slash..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len and n < out.len) : (n += 1) {
        if (p[i] == '%' and i + 2 < p.len) {
            const h = std.fmt.charToDigit(p[i + 1], 16) catch null;
            const l = std.fmt.charToDigit(p[i + 2], 16) catch null;
            if (h != null and l != null) {
                out[n] = h.? << 4 | l.?;
                i += 3;
                continue;
            }
        }
        out[n] = p[i];
        i += 1;
    }
    return out[0..n];
}

test "uri lists" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/a b.png", pathOfUri("file:///home/me/a%20b.png\r", &buf).?);
    try std.testing.expectEqualStrings("/x", pathOfUri("file://host/x", &buf).?);
    try std.testing.expect(pathOfUri("# comment", &buf) == null);
    try std.testing.expect(pathOfUri("https://example.com/x", &buf) == null);
}

test {
    _ = keymap_mod;
}

// ---- Docs/improvements.html C5, B9, B10, B11: against a fake compositor (a socket pair) ----

const fake = struct {
    fn pair() [2]i32 {
        var sv: [2]i32 = undefined;
        _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv);
        return sv;
    }

    fn msg(buf: *std.ArrayList(u8), obj: u32, op: u16, args: []const u32) void {
        const len: u32 = @intCast(8 + 4 * args.len);
        const so: u32 = (len << 16) | op;
        buf.appendSlice(std.testing.allocator, std.mem.asBytes(&obj)) catch unreachable;
        buf.appendSlice(std.testing.allocator, std.mem.asBytes(&so)) catch unreachable;
        for (args) |a| buf.appendSlice(std.testing.allocator, std.mem.asBytes(&a)) catch unreachable;
    }

    fn sendWithFd(sock: i32, bytes: []const u8, fd: i32) void {
        var iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
        var ctrl: [24]u8 align(8) = @splat(0);
        std.mem.writeInt(usize, ctrl[0..8], 20, .little);
        std.mem.writeInt(i32, ctrl[8..12], linux.SOL.SOCKET, .little);
        std.mem.writeInt(i32, ctrl[12..16], linux.SCM.RIGHTS, .little);
        std.mem.writeInt(i32, ctrl[16..20], fd, .little);
        var m = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctrl, .controllen = 24, .flags = 0 };
        _ = linux.sendmsg(sock, &m, 0);
    }

    fn nowMs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }

    fn display(fd: i32) !*Display {
        const d = try std.testing.allocator.create(Display);
        d.* = .{ .gpa = std.testing.allocator, .sw = .init(std.testing.allocator) };
        d.fd = fd;
        return d;
    }

    fn done(d: *Display, sv: [2]i32) void {
        d.sw.deinit();
        std.testing.allocator.destroy(d);
        _ = linux.close(sv[0]);
        _ = linux.close(sv[1]);
    }
};

test "B9: a repeat rate of 0 (no repeat) doesn't make the loop spin while a key is held" {
    const sv = fake.pair();
    const d = try fake.display(sv[0]);
    defer fake.done(d, sv);
    d.keyboard = 50;
    var input: zui.Input = .{};
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    fake.msg(&b, 50, 5, &.{ 0, 10 }); // repeat_info(rate 0, delay 10)
    fake.msg(&b, 50, 3, &.{ 1, 0, 30, 1 }); // a key goes down
    _ = linux.write(sv[1], b.items.ptr, b.items.len);
    _ = try d.wait(&input, 100);
    var wakes: usize = 0;
    const t0 = fake.nowMs();
    while (fake.nowMs() - t0 < 200) : (wakes += 1) _ = try d.wait(&input, 50);
    try std.testing.expect(wakes <= 6);
    try std.testing.expect(d.repeat_code == null);
}

test "B10: an fd sent to a data source already dropped is taken and closed" {
    const sv = fake.pair();
    const d = try fake.display(sv[0]);
    defer fake.done(d, sv);
    d.dead_sources[0] = 77;
    var input: zui.Input = .{};
    var p: [2]i32 = undefined;
    _ = linux.pipe2(&p, .{ .CLOEXEC = true });
    defer _ = linux.close(p[0]);
    // wl_data_source.send("text/plain", fd) for source 77
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const obj: u32 = 77;
    const so: u32 = ((8 + 4 + 12) << 16) | 1;
    const n: u32 = 11;
    try b.appendSlice(std.testing.allocator, std.mem.asBytes(&obj));
    try b.appendSlice(std.testing.allocator, std.mem.asBytes(&so));
    try b.appendSlice(std.testing.allocator, std.mem.asBytes(&n));
    try b.appendSlice(std.testing.allocator, "text/plain\x00\x00");
    fake.sendWithFd(sv[1], b.items, p[1]);
    _ = linux.close(p[1]);
    _ = try d.wait(&input, 100);
    try std.testing.expectEqual(@as(usize, 0), d.ifd_n);
    // Our copy was closed: the reader sees the end at once.
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(p[0], &one, 1));
}

test "B11: leaving lets go of held buttons and keys (no release comes after a window move)" {
    const sv = fake.pair();
    const d = try fake.display(sv[0]);
    defer fake.done(d, sv);
    d.pointer = 60;
    d.keyboard = 50;
    var input: zui.Input = .{};
    input.onMouseButton(.left, true);
    input.onKeyPress(.a);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    fake.msg(&b, 60, 1, &.{ 1, 100 }); // pointer leave(serial, surface)
    fake.msg(&b, 50, 2, &.{ 1, 100 }); // keyboard leave(serial, surface)
    _ = linux.write(sv[1], b.items.ptr, b.items.len);
    _ = try d.wait(&input, 100);
    try std.testing.expect(!input.mouse_down.contains(.left));
    try std.testing.expect(input.mouse_released.contains(.left));
    try std.testing.expect(!input.keys_down.contains(.a));
}

test "C5: five new OS windows in one present don't overflow the fd queue" {
    const sv = fake.pair();
    const d = try fake.display(sv[0]);
    defer fake.done(d, sv);
    d.shm = 3;
    d.compositor = 4;
    const gpa = std.testing.allocator;
    var font = try zui.Font.initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    var list: *const zui.DrawList = undefined;
    for (0..2) |_| {
        ui.beginFrame(.{ .width = 200, .height = 200, .dt = 0.016 });
        inline for (.{ "A", "B", "C", "D", "E" }) |t| if (ui.beginWindow(t, .{ .size = .{ .x = 50, .y = 50 }, .detached = true })) ui.endWindow();
        list = try ui.endFrame();
    }
    d.surfaces[0] = .{ .configured = true, .width = 20, .height = 20, .surface = 100, .pool = 101, .pool_size = 1 << 20, .mem_fd = -1 };
    const mm = linux.mmap(null, 1 << 20, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    d.surfaces[0].mem = @ptrFromInt(mm);
    d.surface_count = 1;
    for (ui.viewports(), 0..) |vp, k| {
        d.surfaces[1 + k] = .{ .viewport = vp.id, .configured = true, .width = 20, .height = 20, .surface = @intCast(200 + k * 10), .toplevel = @intCast(201 + k * 10) };
        d.surface_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), ui.viewports().len);
    d.next_id = 1000;
    try d.present(&ui, list);
    try std.testing.expect(d.onfd <= d.ofds.len);
}
