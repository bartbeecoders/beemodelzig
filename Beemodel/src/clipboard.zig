// The clipboard (clipboard.s): copying makes a wl_data_source offering UTF-8
// text and sets it as the selection; when another program pastes, the
// compositor asks for the text (send: an fd) and we write it. Pasting reads
// the selection's offer through a pipe (receive). Our own selection is pasted
// directly. Without a data device manager it still works inside BeeModel.
const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland.zig");
const drop = @import("drop.zig");

const CAP = 65536;
const DDM_CREATE_SOURCE = 0;
const DDM_GET_DEVICE = 1;
const SRC_OFFER = 0;
const SRC_DESTROY = 1;
const DEV_SET_SEL = 1;
const OFFER_RECEIVE = 1;
const OFFER_DESTROY = 2;

const mimes = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

pub var win: ?*wl.Window = null;
var ddm: u32 = 0;
var dev: u32 = 0;
var src: u32 = 0; // our wl_data_source while we own the selection
var offer_new: u32 = 0; // the newest wl_data_offer
var offer_new_mime: i32 = -1; // the best text type it has
var offer_sel: u32 = 0; // the selection's offer
var offer_sel_mime: i32 = -1;
var own: bool = false; // the selection is ours
var buf: [CAP]u8 = undefined;
var len: usize = 0;
var sigpipe_off = false;

/// The manager appeared in the registry.
pub fn global(w: *wl.Window, name: u32, iface: []const u8, ver: u32) bool {
    if (!std.mem.eql(u8, iface, "wl_data_device_manager") or ddm != 0) return false;
    ddm = w.bind(name, iface, @min(ver, 3));
    return true;
}

/// Our data device, once the seat and the manager are known.
pub fn init(w: *wl.Window) void {
    win = w;
    if (ddm == 0 or w.seat == 0 or dev != 0) return;
    dev = w.newId();
    w.req(ddm, DDM_GET_DEVICE, .{ dev, w.seat });
}

/// It becomes the clipboard.
pub fn copy(text: []const u8) void {
    len = @min(text.len, CAP - 1);
    @memcpy(buf[0..len], text[0..len]);
    own = true;
    const w = win orelse return;
    if (dev == 0) return; // (ours only)
    if (src != 0) w.req(src, SRC_DESTROY, .{});
    src = w.newId();
    w.req(ddm, DDM_CREATE_SOURCE, .{src});
    for (mimes) |m| w.req(src, SRC_OFFER, .{wl.Window.Str{ .s = m }});
    w.req(dev, DEV_SET_SEL, .{ src, w.last_serial });
    w.flush() catch {};
}

/// The clipboard's text into dest (bytes). Another program's comes through a
/// pipe, read until its end, a second at most.
pub fn paste(dest: []u8) usize {
    if (own) {
        const n = @min(len, dest.len);
        @memcpy(dest[0..n], buf[0..n]);
        return n;
    }
    const w = win orelse return 0;
    if (offer_sel == 0 or offer_sel_mime < 0) return 0;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return 0;
    w.req(offer_sel, OFFER_RECEIVE, .{ wl.Window.Str{ .s = mimes[@intCast(offer_sel_mime)] }, wl.Window.Fd{ .fd = fds[1] } });
    w.flush() catch {};
    _ = linux.close(fds[1]);
    var n: usize = 0;
    while (n < dest.len) {
        var p = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&p, 1, 1000);
        if (linux.errno(pr) == .INTR) continue;
        if (linux.errno(pr) != .SUCCESS or pr == 0) break;
        const rc = linux.read(fds[0], dest[n..].ptr, dest.len - n);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        n += rc;
    }
    _ = linux.close(fds[0]);
    return n;
}

/// Write the text to a program that asked for it (never for long, and a
/// reader that went away is no signal).
fn send(fd: i32) void {
    if (!sigpipe_off) {
        sigpipe_off = true;
        var act = std.mem.zeroes(linux.Sigaction);
        act.handler.handler = linux.SIG.IGN;
        _ = linux.sigaction(linux.SIG.PIPE, &act, null);
    }
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, fl | 0o4000); // O_NONBLOCK
    var off: usize = 0;
    while (off < len) {
        const rc = linux.write(fd, buf[off..].ptr, len - off);
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
    _ = linux.close(fd);
}

/// An event of ours? (wlext.event)
pub fn event(w: *wl.Window, obj: u32, op: u16, r: *wl.Window.Rd) bool {
    if (obj == dev) {
        switch (op) {
            0 => { // data_offer(new id): types follow
                offer_new = r.u();
                offer_new_mime = -1;
                drop.newOffer();
            },
            1 => drop.enter(w, r, offer_new), // files dragged over us
            2 => drop.leave(w, offer_sel),
            3 => drop.motion(r),
            4 => drop.dropped(w, offer_sel),
            5 => { // selection(offer or 0)
                const o = r.u();
                if (offer_sel != 0 and offer_sel != o) w.req(offer_sel, OFFER_DESTROY, .{});
                offer_sel = o;
                offer_sel_mime = if (o == offer_new) offer_new_mime else -1;
                // someone else's selection now (unless it is the offer of ours)
                if (o != 0 and src == 0) own = false;
            },
            else => {},
        }
        return true;
    }
    if (obj == src) {
        switch (op) {
            1 => { // send(mime, fd): write the text
                _ = r.str();
                const fd = w.popFd();
                if (fd >= 0) send(fd);
            },
            2 => { // cancelled: another program owns it
                w.req(src, SRC_DESTROY, .{});
                src = 0;
                own = false;
            },
            else => {},
        }
        return true;
    }
    if (obj == offer_new) {
        if (op == 0) {
            const m = r.str();
            drop.offered(m);
            for (mimes, 0..) |t, i| {
                if (std.mem.eql(u8, m, t) and (offer_new_mime < 0 or i < offer_new_mime)) offer_new_mime = @intCast(i);
            }
        }
        return true;
    }
    return obj == offer_sel;
}
