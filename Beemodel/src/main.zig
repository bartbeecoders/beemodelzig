// BeeModel, Zig prototype: entry point and event loop.
//
//   beemodel                      open the window (Wayland)
//   beemodel --shot out.ppm ...   render headless to a PPM, after scripted input:
//       --size WxH  --move X,Y  --click X,Y  --rclick X,Y  --mclick X,Y  --dbl X,Y
//       --drag X,Y,X2,Y2  --mdrag ...  --shift-drag ...  --wheel X,Y,STEPS
//       --key KEY (g, ctrl+z, shift+a, f3, kp1, enter, or an evdev code)
//       --type TEXT  --wait MS  --click-label [KIND:]LABEL  --rclick-label ...
//       --move-label ...  --dbl-label ...  --expect-label ...  --dump-ui FILE
const std = @import("std");
const linux = std.os.linux;
const gfx = @import("gfx.zig");
const wl = @import("wayland.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");

var window: wl.Window = .{};
var canvas: gfx.Canvas = .{ .px = undefined, .w = 0, .h = 0, .clip = .{} };
var aux_cap: usize = 0;
var zbuf: []f32 = &.{};
var ids: []u16 = &.{};

/// Headless runs leave the preferences alone (tests start from defaults).
fn args_flat(args: []const [:0]const u8) []const u8 {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--shot")) return "--shot";
    }
    return "";
}

fn nowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Size the canvas (and its depth / id buffers) to w x h.
fn resizeCanvas(px: [*]u32, w_comp: i32, h_comp: i32) !void {
    const sc = @import("scale.zig");
    _ = sc.apply();
    const w = sc.px(w_comp);
    const h = sc.px(h_comp);
    const n: usize = @intCast(w * h);
    if (n > aux_cap) {
        const a = std.heap.page_allocator;
        if (aux_cap > 0) {
            a.free(zbuf);
            a.free(ids);
        }
        zbuf = try a.alloc(f32, n);
        ids = try a.alloc(u16, n);
        @memset(ids, 0);
        aux_cap = n;
    }
    canvas = .{ .px = px, .w = w, .h = h, .clip = .{ .w = sc.units(w), .h = sc.units(h) }, .zbuf = zbuf.ptr, .ids = ids.ptr, .s = sc.q16(), .uw = sc.units(w), .uh = sc.units(h) };
}

/// beemodel --link: the address to mirror once the window is up.
var link_target: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // beemodel --mcp-bridge: stdin/stdout <-> the running app's MCP socket (mcp.zig)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--mcp-bridge")) linux.exit_group(@import("mcp.zig").bridge(init.environ_map.get("XDG_RUNTIME_DIR"), init.environ_map.get("BEEMODEL_SOCKET")));
    @import("text.zig").init(init.environ_map.get("BEEMODEL_FONT"), init.environ_map.get("BEEMODEL_MONO_FONT"));
    app.init();
    if (std.mem.eql(u8, args_flat(args), "--shot")) {
        // tests and fuzzing: a home of their own, writes only under /tmp
        _ = linux.mkdir("/tmp/beemodel-headless", 0o755);
        @import("filebrowser.zig").setHome("/tmp/beemodel-headless");
        @import("files.zig").headless = true;
    } else @import("filebrowser.zig").setHome(init.environ_map.get("HOME"));
    // (--eval / --run: BeeScript without a window; the preferences stay unread, as the original's)
    const script_cli = args.len >= 2 and (std.mem.eql(u8, args[1], "--eval") or std.mem.eql(u8, args[1], "--run"));
    @import("prefs.zig").init(if (script_cli or std.mem.indexOf(u8, args_flat(args), "--shot") != null) null else init.environ_map.get("HOME"));
    @import("ai.zig").init();
    if (!script_cli and std.mem.indexOf(u8, args_flat(args), "--shot") == null) @import("ai.zig").secretsInit(init.environ_map.get("HOME"));
    @import("jobs.zig").want_threads = @intCast(@import("prefpages.zig").threads);
    @import("jobs.zig").init();
    app.now_ms = nowMs();

    if (script_cli) linux.exit_group(scriptCli(args));
    // beemodel --link host:port | unix:<path>: the window, mirroring (main.s .Lcli_link)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--link")) {
        if (args.len < 3) {
            const e = "beemodel: --eval needs BeeScript code, --run a file, --link an address\n";
            _ = linux.write(2, e, e.len);
            linux.exit_group(1);
        }
        link_target = args[2];
    }
    // the content library's thumbnail child (libui.zig): one asset, path-traced, no window
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--lib-thumbnail")) linux.exit_group(@import("libui.zig").thumbChild(args[2]));
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--shot") and i + 1 < args.len) return shot(args, args[i + 1]);
        if (std.mem.eql(u8, a, "--selftest")) linux.exit_group(@import("selftest.zig").run());
    }

    // a signal or a compositor gone ends the loop: the last autosave comes first
    const autosave = @import("autosave.zig");
    catchEndings();

    window.connect(init.environ_map) catch |e| {
        std.debug.print("beemodel: cannot open a Wayland window ({s}). Is a Wayland compositor running?\n", .{@errorName(e)});
        std.debug.print("(headless test: beemodel --shot out.ppm)\n", .{});
        return e;
    };
    app.win = &window;
    // the MCP server for AI agents (mcp.zig): its sockets in $XDG_RUNTIME_DIR
    const mcp = @import("mcp.zig");
    mcp.init(init.environ_map.get("XDG_RUNTIME_DIR"), init.environ_map.get("BEEMODEL_NO_MCP"), init.environ_map.get("BEEMODEL_AGENT_PERMISSION"));
    defer mcp.shutdown();
    defer @import("link.zig").shutdown(); // (the live link's sockets)
    defer @import("ai.zig").kill(); // (an AI connection's child goes too)
    defer @import("hi3d.zig").kill(); // (and Image to 3D's helper: hz_kill)
    var dummy: [1]u32 = .{0};
    try resizeCanvas(&dummy, window.width, window.height);
    @import("welcome.zig").atStart(init.environ_map.get("BEEMODEL_WELCOME"));

    var held_key: u32 = 0;
    var repeat_at: i64 = 0;
    @import("jobui.zig").present_fn = jobFrame;
    // the GPU helper in the background: the first render finds it ready
    @import("gpu.zig").device = @enumFromInt(@as(u8, @intCast(std.math.clamp(@import("prefs.zig").render_device, 0, 3))));
    @import("gpu.zig").prewarm();
    defer @import("gpu.zig").stop();

    var cache: [480]u8 = undefined;
    if (autosave.folderFor(&cache, init.environ_map.get("XDG_CACHE_HOME"), init.environ_map.get("HOME"))) |d| autosave.init(d);
    defer autosave.atExit(app.quit);
    if (init.environ_map.get("HOME")) |h| @import("wsfile.zig").initRemembered(h);
    // beemodel scene.bee
    if (args.len > 1 and args[1].len > 0 and args[1][0] != '-') @import("files.zig").openFrom(args[1]);
    // beemodel --link host:port: mirror that session (main.s, after mcp_init)
    if (link_target) |t| _ = @import("link.zig").connect(t);

    var world_wait: ?i32 = null;
    while (!app.quit and !window.closed and !ending) {
        window.flush() catch break; // the compositor is gone: as below
        app.now_ms = nowMs();
        var timeout: i32 = app.tick();
        if (held_key != 0) {
            const t: i32 = @intCast(@max(0, repeat_at - app.now_ms));
            timeout = if (timeout < 0) t else @min(timeout, t);
        }
        if (world_wait) |t| timeout = if (timeout < 0) t else @min(timeout, t); // (cells waiting: look soon)
        if (app.dirty and !window.frame_pending) timeout = 0;
        var pfd: [1 + mcp.MAX_CLIENTS + 1 + 1 + 1 + @import("link.zig").MAX_POLLFDS + @import("cosync.zig").MAX_FDS]linux.pollfd = undefined;
        pfd[0] = .{ .fd = window.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_mcp = mcp.pollfds(pfd[1..]);
        // + the AI connection's child (ai.zig: read after the agents' requests)
        const n_ai = @import("ai.zig").pollfds(pfd[1 + n_mcp ..]);
        // + Image to 3D's helper (hi3d.zig: read in app.tick)
        const n_hz = @import("hi3d.zig").pollfds(pfd[1 + n_mcp + n_ai ..]);
        // + the live link's (link.zig: the listener, its peers, the mirror's connection)
        const n_lk = @import("link.zig").pollfds(pfd[1 + n_mcp + n_ai + n_hz ..]);
        // + co-editing's (cosync.zig: the listener, its peers)
        const n_co = @import("cosync.zig").pollfds(pfd[1 + n_mcp + n_ai + n_hz + n_lk ..]);
        _ = linux.poll(&pfd, @intCast(1 + n_mcp + n_ai + n_hz + n_lk + n_co), timeout);
        app.now_ms = nowMs();
        if (pfd[0].revents & linux.POLL.IN != 0) window.read() catch break;
        if (pfd[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) break;
        window.dispatch();

        for (window.queue[0..window.qlen]) |ev| {
            switch (ev) {
                .resize => try resizeCanvas(canvas.px, window.width, window.height),
                .key => |k| {
                    if (k.pressed and repeatable(k.key)) {
                        held_key = k.key;
                        repeat_at = app.now_ms + window.repeat_delay;
                    } else if (!k.pressed and k.key == held_key) held_key = 0;
                },
                .focus => |f| if (!f) {
                    held_key = 0;
                },
                else => {},
            }
            app.onInput(&canvas, ev);
        }
        window.qlen = 0;

        if (@import("jobui.zig").runPending()) {
            app.afterJob();
            held_key = 0;
        }

        // agents' requests, between input and the frame
        mcp.handle(pfd[1 .. 1 + n_mcp]);
        @import("link.zig").tick(); // the live link: peers, changes out (link_tick)
        @import("cosync.zig").tick(); // co-editing: operations in and out (co_tick)
        @import("ai.zig").tick(); // the AI connection's child: its output
        world_wait = @import("world.zig").frame(); // world cells in and out for the camera

        if (held_key != 0 and app.now_ms >= repeat_at and window.repeat_rate > 0) {
            app.onInput(&canvas, .{ .key = .{ .key = held_key, .pressed = true } });
            repeat_at = app.now_ms + @divTrunc(1000, window.repeat_rate);
        }

        if (app.dirty and !window.frame_pending and window.configured) {
            if (window.acquire()) |px| {
                try resizeCanvas(px, window.width, window.height);
                const ft0 = nowNs(); // (frametime() in BeeScript: the drawing's time)
                app.frame(&canvas);
                @import("bscript.zig").frameDrawn(@intCast(@max(0, nowNs() - ft0)), 0);
                window.present();
                @import("panelwin.zig").drawAll();
                app.frameDrawn();
                app.dirty = false;
            }
        }
    }
}

/// beemodel --eval 'code' / --run file.bees (main.s): the scene without a
/// window, the script run, what it printed to stdout; exit 0 ok, 1 a script
/// error, 2 an unreadable file.
fn scriptCli(args: []const [:0]const u8) u8 {
    const bs = @import("bscript.zig");
    if (args.len < 3) {
        const e = "beemodel: --eval needs BeeScript code, --run a file, --link an address\n";
        _ = linux.write(2, e, e.len);
        return 1;
    }
    const rc = if (std.mem.eql(u8, args[1], "--eval")) bs.eval(args[2], false) else bs.runFile(args[2]);
    const o = bs.output();
    var w: usize = 0;
    while (w < o.len) {
        const r = linux.write(1, o[w..].ptr, o.len - w);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        w += r;
    }
    return rc;
}

/// SIGTERM or SIGHUP came (a logout, a kill): the main loop ends at its next turn.
var ending = false;

fn onEnding(_: linux.SIG) callconv(.c) void {
    ending = true;
}

/// A compositor that goes away must not take the unsaved scene with it: its
/// socket gives an error here, not a SIGPIPE, and TERM and HUP end the loop.
fn catchEndings() void {
    var act = linux.Sigaction{ .handler = .{ .handler = onEnding }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
    _ = linux.sigaction(.TERM, &act, null);
    _ = linux.sigaction(.HUP, &act, null);
    act.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.PIPE, &act, null);
}

/// A frame while a job runs: the compositor is answered, input waits.
fn jobFrame() void {
    window.flush() catch return;
    var pfd = [1]linux.pollfd{.{ .fd = window.fd, .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&pfd, 1, 0);
    if (pfd[0].revents & linux.POLL.IN != 0) window.read() catch return;
    window.dispatch();
    // Esc is the one key a long job listens to; the rest of the input waits
    // for it to end (but for the pointer's path: its queue is small)
    var kept: usize = 0;
    for (window.queue[0..window.qlen]) |ev| {
        if (ev == .key and ev.key.key == 1) {
            if (ev.key.pressed) @import("jobui.zig").stop = true;
            continue;
        }
        if (ev == .motion) continue;
        window.queue[kept] = ev;
        kept += 1;
    }
    window.qlen = kept;
    if (window.frame_pending or !window.configured) return;
    const px = window.acquire() orelse return;
    resizeCanvas(px, window.width, window.height) catch return;
    app.now_ms = nowMs();
    app.frame(&canvas);
    window.present();
    window.flush() catch {};
}

fn repeatable(key: u32) bool {
    // modifiers and Escape do not repeat
    return switch (key) {
        1, 29, 42, 54, 56, 97, 100, 125, 126 => false,
        else => true,
    };
}

// --- headless screenshots (testing without a compositor) ---------------------------

fn parsePair(s: []const u8) [2]i32 {
    var it = std.mem.tokenizeAny(u8, s, ",x");
    const a = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    const b = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    return .{ a, b };
}

/// More frames while Zui's layout settles (a dialog sizing itself), as Zui's
/// own script player does: the next step finds its widgets where they are.
fn settle() void {
    var k: u8 = 0;
    while (@import("zuihost.zig").settling() and k < 4) : (k += 1) app.frame(&canvas);
}

/// The driver's arguments that are pointer events (they pile up between frames as a window's do).
fn pointerArg(a: []const u8) bool {
    for ([_][]const u8{ "--move", "--press", "--release", "--wheel", "--mods" }) |p| if (std.mem.eql(u8, a, p)) return true;
    return !std.mem.startsWith(u8, a, "--");
}

fn motion(x: i32, y: i32) void {
    app.onInput(&canvas, .{ .motion = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) } });
}

fn click(x: i32, y: i32, button: u32) void {
    motion(x, y);
    app.onInput(&canvas, .{ .button = .{ .button = button, .pressed = true } });
    app.onInput(&canvas, .{ .button = .{ .button = button, .pressed = false } });
    app.now_ms += 1000; // no accidental double-clicks
}

/// The centre of the widget recorded with this label in the last frame
/// ("kind:label" picks a kind too). Exact match first, then a prefix.
fn findLabel(spec: []const u8) ?[2]i32 {
    var kind: []const u8 = "";
    var label = spec;
    if (std.mem.indexOfScalar(u8, spec, ':')) |c| {
        kind = spec[0..c];
        label = spec[c + 1 ..];
    }
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        for (ui.rec[0..ui.rec_n]) |*e| {
            const l = e.label[0..e.len];
            if (kind.len > 0 and !std.mem.eql(u8, kind, e.kind)) continue;
            const ok = if (pass == 0) std.mem.eql(u8, l, label) else std.ascii.startsWithIgnoreCase(l, label);
            if (ok) return .{ e.r.x + @divTrunc(e.r.w, 2), e.r.y + @divTrunc(e.r.h, 2) };
        }
    }
    return null;
}

const key_names = [_]struct { []const u8, u32 }{
    .{ "esc", 1 },     .{ "enter", 28 },    .{ "tab", 15 },      .{ "space", 57 },     .{ "backspace", 14 },
    .{ "delete", 111 }, .{ "up", 103 },     .{ "down", 108 },    .{ "left", 105 },     .{ "right", 106 },
    .{ "home", 102 },  .{ "end", 107 },     .{ "pageup", 104 },  .{ "pagedown", 109 }, .{ "minus", 12 },
    .{ "f1", 59 },     .{ "f2", 60 },       .{ "f3", 61 },       .{ "f4", 62 },        .{ "f5", 63 },
    .{ "f6", 64 },     .{ "f7", 65 },       .{ "f8", 66 },       .{ "f9", 67 },        .{ "f10", 68 },
    .{ "f11", 87 },    .{ "f12", 88 },      .{ "kp0", 82 },      .{ "kp1", 79 },       .{ "kp2", 80 },
    .{ "kp3", 81 },    .{ "kp4", 75 },      .{ "kp5", 76 },      .{ "kp6", 77 },       .{ "kp7", 71 },
    .{ "kp8", 72 },    .{ "kp9", 73 },      .{ "kpdot", 83 },    .{ "kpenter", 96 },   .{ "comma", 51 },
    .{ "period", 52 },
};

/// "ctrl+shift+z", "g", "f3", "kp1" or an evdev code -> (code, mods).
fn parseKey(spec: []const u8) ?struct { u32, u32 } {
    var mods: u32 = 0;
    var rest = spec;
    while (true) {
        if (std.ascii.startsWithIgnoreCase(rest, "ctrl+")) {
            mods |= wl.MOD_CTRL;
            rest = rest[5..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "shift+")) {
            mods |= wl.MOD_SHIFT;
            rest = rest[6..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "alt+")) {
            mods |= wl.MOD_ALT;
            rest = rest[4..];
        } else break;
    }
    if (std.fmt.parseInt(u32, rest, 10)) |c| {
        if (rest.len > 1) return .{ c, mods };
    } else |_| {}
    for (key_names) |kn| {
        if (std.ascii.eqlIgnoreCase(kn[0], rest)) return .{ kn[1], mods };
    }
    if (rest.len == 1) {
        if (@import("keyboard.zig").codeFor(std.ascii.toLower(rest[0]))) |c| return .{ c[0], mods | (if (c[1]) @as(u32, wl.MOD_SHIFT) else 0) };
    }
    return null;
}

var held_mods: u32 = 0;

fn pressKey(code: u32, mods: u32) void {
    app.onInput(&canvas, .{ .mods = mods | held_mods });
    app.onInput(&canvas, .{ .key = .{ .key = code, .pressed = true } });
    app.onInput(&canvas, .{ .key = .{ .key = code, .pressed = false } });
    app.onInput(&canvas, .{ .mods = held_mods });
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("beemodel --shot: " ++ fmt ++ "\n", args);
}

fn shot(args: []const [:0]const u8, out: []const u8) !void {
    var w: i32 = 1280;
    var h: i32 = 800;
    var dump: ?[]const u8 = null;
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            const p = parsePair(args[i + 1]);
            w = p[0];
            h = p[1];
        }
        if (std.mem.eql(u8, a, "--dump-ui") and i + 1 < args.len) dump = args[i + 1];
    }
    const a = std.heap.page_allocator;
    const sc = @import("scale.zig");
    sc.ptr_in_units = true;
    for (args, 0..) |arg, ai| {
        // the screen's scale (1/120ths) and the UI scale (percent) of a window
        if (std.mem.eql(u8, arg, "--comp-scale") and ai + 1 < args.len) sc.comp_s120 = std.fmt.parseInt(u32, args[ai + 1], 10) catch 120;
        if (std.mem.eql(u8, arg, "--ui-scale") and ai + 1 < args.len) sc.pref = std.fmt.parseInt(u32, args[ai + 1], 10) catch 100;
    }
    const comp_w = w;
    const comp_h = h;
    w = sc.px(comp_w);
    h = sc.px(comp_h);
    const px = try a.alloc(u32, @intCast(w * h));
    try resizeCanvas(px.ptr, comp_w, comp_h);
    app.frame(&canvas); // first draw fills the id buffer
    settle(); // (and Zui's layout settles before the first step looks a widget up)
    var failed = false;
    var hold = false;
    var mcp_on = false;
    defer if (mcp_on) @import("mcp.zig").shutdown();
    defer @import("ai.zig").kill();
    // tests of the autosave: its folder (only under /tmp), how often, a process to kill
    for (args, 0..) |x, ai| {
        if (std.mem.eql(u8, x, "--autosave-every") and ai + 1 < args.len) @import("prefs.zig").autosave = std.fmt.parseInt(i32, args[ai + 1], 10) catch 25;
    }
    for (args, 0..) |x, ai| {
        if (!std.mem.eql(u8, x, "--autosave-dir") or ai + 1 >= args.len) continue;
        if (std.mem.startsWith(u8, args[ai + 1], "/tmp/")) @import("autosave.zig").init(args[ai + 1]) else {
            say("--autosave-dir: only under /tmp", .{});
            failed = true;
        }
        app.frame(&canvas);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const nxt: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        // Pointer events a Zui part (the viewport) has not seen yet: a
        // window draws a frame between them and whatever comes next (an
        // operator, a key, a look at the state), so the driver does too.
        if (@import("zuihost.zig").pointerPending() and !pointerArg(arg)) {
            app.frame(&canvas);
        }
        if (std.mem.eql(u8, arg, "--move")) {
            const p = parsePair(nxt);
            motion(p[0], p[1]);
        } else if (std.mem.eql(u8, arg, "--click") or std.mem.eql(u8, arg, "--rclick") or std.mem.eql(u8, arg, "--mclick")) {
            const p = parsePair(nxt);
            click(p[0], p[1], if (arg[2] == 'r') wl.BTN_RIGHT else if (arg[2] == 'm') wl.BTN_MIDDLE else wl.BTN_LEFT);
        } else if (std.mem.eql(u8, arg, "--dbl")) {
            const p = parsePair(nxt);
            motion(p[0], p[1]);
            for (0..2) |_| {
                app.onInput(&canvas, .{ .button = .{ .button = wl.BTN_LEFT, .pressed = true } });
                app.onInput(&canvas, .{ .button = .{ .button = wl.BTN_LEFT, .pressed = false } });
                app.frame(&canvas);
                app.now_ms += 100;
            }
            app.now_ms += 1000;
        } else if (std.mem.eql(u8, arg, "--click-label") or std.mem.eql(u8, arg, "--rclick-label") or std.mem.eql(u8, arg, "--move-label") or std.mem.eql(u8, arg, "--dbl-label")) {
            if (findLabel(nxt)) |p| {
                switch (arg[2]) {
                    'c' => click(p[0], p[1], wl.BTN_LEFT),
                    'r' => click(p[0], p[1], wl.BTN_RIGHT),
                    'm' => motion(p[0], p[1]),
                    else => {
                        motion(p[0], p[1]);
                        for (0..2) |_| {
                            app.onInput(&canvas, .{ .button = .{ .button = wl.BTN_LEFT, .pressed = true } });
                            app.onInput(&canvas, .{ .button = .{ .button = wl.BTN_LEFT, .pressed = false } });
                            app.frame(&canvas);
                            app.now_ms += 100;
                        }
                        app.now_ms += 1000;
                    },
                }
            } else {
                say("no widget labelled '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--drag") or std.mem.eql(u8, arg, "--mdrag") or std.mem.eql(u8, arg, "--shift-drag")) {
            var it = std.mem.tokenizeScalar(u8, nxt, ',');
            var v: [4]f32 = undefined;
            for (&v) |*c| c.* = @floatFromInt(std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0);
            const btn: u32 = if (arg[2] == 'm') wl.BTN_MIDDLE else wl.BTN_LEFT;
            if (arg[2] == 's') app.onInput(&canvas, .{ .mods = wl.MOD_SHIFT });
            app.onInput(&canvas, .{ .motion = .{ .x = v[0], .y = v[1] } });
            app.onInput(&canvas, .{ .button = .{ .button = btn, .pressed = true } });
            var s: f32 = 1;
            while (s <= 10) : (s += 1) {
                app.onInput(&canvas, .{ .motion = .{ .x = v[0] + (v[2] - v[0]) * s / 10, .y = v[1] + (v[3] - v[1]) * s / 10 } });
                app.frame(&canvas);
            }
            app.onInput(&canvas, .{ .button = .{ .button = btn, .pressed = false } });
            if (arg[2] == 's') app.onInput(&canvas, .{ .mods = 0 });
        } else if (std.mem.eql(u8, arg, "--press") or std.mem.eql(u8, arg, "--release")) {
            // the left button alone, at X,Y (what happens in between: --move, --key ...)
            const p = parsePair(nxt);
            motion(p[0], p[1]);
            app.onInput(&canvas, .{ .button = .{ .button = wl.BTN_LEFT, .pressed = arg[2] == 'p' } });
        } else if (std.mem.eql(u8, arg, "--wheel")) {
            // --wheel X,Y,STEPS (negative: towards you)
            var it = std.mem.tokenizeScalar(u8, nxt, ',');
            const x = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            const st = std.fmt.parseInt(i32, it.next() orelse "1", 10) catch 1;
            motion(x, y);
            app.onInput(&canvas, .{ .wheel = @floatFromInt(st) });
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "--shift-key")) {
            if (parseKey(nxt)) |k| {
                pressKey(k[0], k[1] | (if (arg[2] == 's') @as(u32, wl.MOD_SHIFT) else 0));
            } else {
                say("unknown key '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--keydown") or std.mem.eql(u8, arg, "--keyup")) {
            // hold a key (pies): --keydown z --wait 300 --move ... --keyup z
            if (parseKey(nxt)) |k| {
                if (arg[5] == 'd') {
                    app.onInput(&canvas, .{ .mods = k[1] });
                    app.onInput(&canvas, .{ .key = .{ .key = k[0], .pressed = true } });
                } else {
                    app.onInput(&canvas, .{ .key = .{ .key = k[0], .pressed = false } });
                    app.onInput(&canvas, .{ .mods = 0 });
                }
            } else {
                say("unknown key '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--type")) {
            var ti: usize = 0;
            while (ti < nxt.len) {
                const cp = @import("text.zig").nextCp(nxt, &ti);
                const code = @import("keyboard.zig").codeFor(cp) orelse {
                    say("--type: no key types U+{X:0>4} in this layout (use --key with a dead key)", .{cp});
                    failed = true;
                    continue;
                };
                app.onInput(&canvas, .{ .mods = if (code[1]) wl.MOD_SHIFT else 0 });
                app.onInput(&canvas, .{ .key = .{ .key = code[0], .pressed = true } });
            }
            app.onInput(&canvas, .{ .mods = 0 });
        } else if (std.mem.eql(u8, arg, "--mods")) {
            // hold modifiers for the next actions: ctrl, shift, alt, ctrl+shift ... or none
            var md: u32 = 0;
            if (std.mem.indexOf(u8, nxt, "ctrl") != null) md |= wl.MOD_CTRL;
            if (std.mem.indexOf(u8, nxt, "shift") != null) md |= wl.MOD_SHIFT;
            if (std.mem.indexOf(u8, nxt, "alt") != null) md |= wl.MOD_ALT;
            held_mods = md;
            app.onInput(&canvas, .{ .mods = md });
        } else if (std.mem.eql(u8, arg, "--keymap")) {
            // an XKB text keymap (xkbcli compile-keymap --layout fr > fr.xkb)
            if (@import("ttf.zig").mapFile(nxt)) |data| {
                if (!@import("keyboard.zig").parse(data)) {
                    say("not an XKB keymap: {s}", .{nxt});
                    failed = true;
                }
            } else {
                say("cannot read {s}", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--wait")) {
            // let time pass (tooltips, toasts)
            const ms = std.fmt.parseInt(i64, nxt, 10) catch 0;
            app.now_ms += ms;
            _ = app.tick();
        } else if (std.mem.eql(u8, arg, "--render-wait")) {
            // a render (F12) to its end
            @import("render.zig").finish();
            app.dirty = true;
            app.frame(&canvas);
            continue;
        } else if (std.mem.eql(u8, arg, "--live-wait")) {
            // the Rendered viewport to its last sample
            app.dirty = true;
            app.frame(&canvas);
            @import("live.zig").finish();
            app.dirty = true;
            app.frame(&canvas);
            continue;
        } else if (std.mem.eql(u8, arg, "--serial-raster")) {
            // plain meshes the one-thread way (the test that the threads change nothing)
            @import("vpraster.zig").enabled = false;
            continue;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            // draw N frames, as when orbiting: time per frame
            const nf = std.fmt.parseInt(usize, std.mem.trimEnd(u8, nxt, "c"), 10) catch 60;
            @import("viewport.zig").cache_enabled = std.mem.indexOf(u8, nxt, "c") != null; // "60c": with the cache
            var worst: i64 = 0;
            const t0 = nowNs();
            var k: usize = 0;
            while (k < nf) : (k += 1) {
                const f0 = nowNs();
                app.dirty = true;
                app.frame(&canvas);
                worst = @max(worst, nowNs() - f0);
            }
            const total = nowNs() - t0;
            std.debug.print("bench: {d} frames at {d}x{d}: {d:.2} ms avg, {d:.2} ms worst\n", .{ nf, w, h, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(nf)) / 1e6, @as(f64, @floatFromInt(worst)) / 1e6 });
        } else if (std.mem.eql(u8, arg, "--bench-lib")) {
            // --bench-lib N: the content library read, searched N times, listed (library.zig)
            const nb = std.fmt.parseInt(usize, nxt, 10) catch 100;
            const lb = @import("library.zig");
            const t0 = nowNs();
            lb.reset();
            lb.init();
            const t1 = nowNs();
            for (0..nb) |_| lb.runOp("lib.search", "a0 red");
            const t2 = nowNs();
            for (0..10) |_| lb.runOp("lib.list", "");
            const t3 = nowNs();
            std.debug.print("bench-lib: {d} assets: read {d:.3} ms, search {d:.4} ms, list {d:.3} ms\n", .{ lb.n, @as(f64, @floatFromInt(t1 - t0)) / 1e6, @as(f64, @floatFromInt(t2 - t1)) / @as(f64, @floatFromInt(nb)) / 1e6, @as(f64, @floatFromInt(t3 - t2)) / 10 / 1e6 });
        } else if (std.mem.eql(u8, arg, "--bench-anim")) {
            // N played frames: evaluated and drawn, time per frame and of the evaluation
            const nf = std.fmt.parseInt(usize, nxt, 10) catch 60;
            const an = @import("anim.zig");
            const fr = @import("frange.zig");
            var eval_ns: i64 = 0;
            var worst: i64 = 0;
            const t0 = nowNs();
            var k: usize = 0;
            while (k < nf) : (k += 1) {
                const f0 = nowNs();
                an.apply(@floatFromInt(fr.r.start + @as(i32, @intCast(k % @as(usize, @intCast(@max(fr.r.end - fr.r.start, 1)))))));
                eval_ns += nowNs() - f0;
                app.dirty = true;
                app.frame(&canvas);
                worst = @max(worst, nowNs() - f0);
            }
            const total = nowNs() - t0;
            std.debug.print("bench-anim: {d} frames at {d}x{d}: {d:.2} ms avg, {d:.2} ms worst, evaluation {d:.3} ms\n", .{ nf, w, h, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(nf)) / 1e6, @as(f64, @floatFromInt(worst)) / 1e6, @as(f64, @floatFromInt(eval_ns)) / @as(f64, @floatFromInt(nf)) / 1e6 });
        } else if (std.mem.eql(u8, arg, "--expect-no-label")) {
            if (findLabel(nxt) != null) {
                say("expected no widget labelled '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--expect-off")) {
            // a widget that is there, greyed
            var off = false;
            for (ui.rec[0..ui.rec_n]) |*e| {
                if (std.mem.eql(u8, e.label[0..e.len], nxt) and !e.enabled) off = true;
            }
            if (!off) {
                say("expected '{s}' greyed", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--expect-focused")) {
            // the keyboard's ring is on this widget
            var on = false;
            if (@import("wg.zig").focused()) |fe| {
                for (ui.rec[0..ui.rec_n]) |*e| {
                    if (std.mem.eql(u8, e.label[0..e.len], nxt) and e.r.x == fe.r.x and e.r.y == fe.r.y) on = true;
                }
            }
            if (!on) {
                say("expected the focus on '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--expect-field")) {
            // --expect-field LABEL=VALUE: the value a field shows
            const eqi = std.mem.indexOfScalar(u8, nxt, '=') orelse 0;
            const wgl = @import("wg.zig");
            var got: []const u8 = "(no such field)";
            var nb: [32]u8 = undefined;
            for (wgl.list[0..wgl.n]) |*e| {
                if (!std.mem.eql(u8, e.name(), nxt[0..eqi])) continue;
                got = if (e.kind == .number) (std.fmt.bufPrint(&nb, "{d}", .{e.val}) catch "") else e.txt();
                if (std.mem.eql(u8, got, nxt[eqi + 1..])) break;
            }
            // (or a field Zui draws: its value as shown, numbers compared as numbers)
            if (!std.mem.eql(u8, got, nxt[eqi + 1 ..])) if (@import("zuihost.zig").fieldValue(nxt[0..eqi])) |zv| {
                got = zv;
                const want = nxt[eqi + 1 ..];
                const shown = std.fmt.parseFloat(f64, std.mem.trim(u8, zv, " ")) catch null;
                const wanted = std.fmt.parseFloat(f64, want) catch null;
                if (shown != null and wanted != null and shown.? == wanted.?) got = want;
            };
            if (!std.mem.eql(u8, got, nxt[eqi + 1..])) {
                say("expected the field {s}, it shows {s}", .{ nxt, got });
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--expect-label")) {
            if (findLabel(nxt) == null) {
                say("expected a widget labelled '{s}'", .{nxt});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "--dump-ui") or std.mem.eql(u8, arg, "--dump-log") or std.mem.eql(u8, arg, "--shot") or std.mem.eql(u8, arg, "--comp-scale") or std.mem.eql(u8, arg, "--ui-scale") or std.mem.eql(u8, arg, "--autosave-dir") or std.mem.eql(u8, arg, "--autosave-every")) {
            i += 1;
            continue;
        } else if (std.mem.eql(u8, arg, "--op")) {
            // a console line, whatever has the focus and whichever areas there are
            @import("editors.zig").runCommand(nxt);
            app.afterInput();
        } else if (std.mem.eql(u8, arg, "--dump-chan")) {
            // --dump-chan OUT;FIRST;LAST;STEP;PATH;PATH...: each path's value, frame by frame
            @import("animtest.zig").dumpChannels(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-force")) {
            // --dump-force OUT;x,y,z;...: force(x, y, z) at each point (fields.zig), appended
            @import("fields.zig").dumpForce(nxt);
        } else if (std.mem.eql(u8, arg, "--play")) {
            // --play "step S F R U RUN" | "look Y P" | "key CODE DOWN" | "dump OUT TAG what...": play mode
            // as the original's playstep / playlook / playkey (play.zig)
            @import("play.zig").driver(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-procgen")) {
            @import("procgen.zig").dumpSpec(nxt); // (tests: terrain, erode, terrace, lsystem)
        } else if (std.mem.eql(u8, arg, "--dump-particles")) {
            // --dump-particles OUT: every particle's numbers as bits, appended (particles.zig)
            @import("particles.zig").dump(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-brep")) {
            // --dump-brep OUT;OBJECT: what brep(name, what) says of its B-rep solid
            @import("bquery.zig").dump(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-nodeval")) {
            // --dump-nodeval IN;OUT: nodeval(material, node, k, x, y, z, u, v) per line (shtest.zig)
            @import("shtest.zig").dumpNodeval(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-uv")) {
            @import("uvtest.zig").dump(nxt);
        } else if (std.mem.eql(u8, arg, "--vselect")) {
            @import("uvtest.zig").vselect(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-rig")) {
            @import("animtest.zig").dumpRig(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-paths")) {
            @import("animtest.zig").dumpPaths(nxt);
        } else if (std.mem.eql(u8, arg, "--select")) {
            @import("animtest.zig").selectObject(nxt);
        } else if (std.mem.eql(u8, arg, "--dump-verts")) {
            // --dump-verts OUT;OBJECT: what an object shows, vertex by vertex
            @import("animtest.zig").dumpVerts(nxt);
        } else if (std.mem.eql(u8, arg, "--print-anim")) {
            @import("animtest.zig").print(nxt);
        } else if (std.mem.eql(u8, arg, "--expect-anim")) {
            // --expect-anim WHAT=VALUE: what the animation holds (animtest.zig)
            if (!@import("animtest.zig").expect(nxt)) failed = true;
        } else if (std.mem.eql(u8, arg, "--expect-faces") or std.mem.eql(u8, arg, "--expect-objects")) {
            // the effect, not that nothing crashed
            const sn = @import("scene.zig");
            const want = std.fmt.parseInt(u64, nxt, 10) catch 0;
            const got: u64 = if (arg[9] == 'f') sn.faceCount() else sn.count;
            if (got != want) {
                say("{s} {d}: there are {d}", .{ arg, want, got });
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--drop")) {
            // what the data device hands over: a text/uri-list
            @import("drop.zig").openList(nxt);
        } else if (std.mem.eql(u8, arg, "--drop-at")) {
            // --drop-at X,Y LIST: a text/uri-list dropped at X,Y, through
            // Zui's drop zones (the frame after it opens the files)
            const p = parsePair(nxt);
            i += 1;
            const list = if (i + 1 < args.len) args[i + 1] else "";
            motion(p[0], p[1]);
            @import("drop.zig").deliver(list, .{ @floatFromInt(p[0]), @floatFromInt(p[1]) });
            app.frame(&canvas);
            settle();
        } else if (std.mem.eql(u8, arg, "--slow-writes")) {
            @import("atomicfile.zig").slow = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--mcp-listen")) {
            // the MCP server, as the window's (the AI Assistant's CLIs reach it)
            const sp = @import("spawn.zig");
            @import("mcp.zig").init(sp.getenv("XDG_RUNTIME_DIR"), null, sp.getenv("BEEMODEL_AGENT_PERMISSION"));
            mcp_on = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--ai-pref")) {
            // --ai-pref "word value": an AI preference (the window's file is not read here)
            const sp = std.mem.indexOfScalar(u8, nxt, ' ') orelse nxt.len;
            if (!@import("ai.zig").loadPref(nxt[0..sp], if (sp < nxt.len) nxt[sp + 1 ..] else "")) {
                say("--ai-pref: no such preference '{s}'", .{nxt[0..sp]});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--ai-wait")) {
            // --ai-wait MS: the AI's request to its end (its child and the
            // agents' requests served meanwhile), MS at most
            const mcp = @import("mcp.zig");
            const ai = @import("ai.zig");
            const lim = std.fmt.parseInt(i64, nxt, 10) catch 10000;
            const t0 = nowMs();
            while ((ai.busy or ai.running()) and nowMs() - t0 < lim) {
                var pf: [mcp.MAX_CLIENTS + 2]linux.pollfd = undefined;
                const n_mcp = mcp.pollfds(pf[0..]);
                const n_ai = ai.pollfds(pf[n_mcp..]);
                _ = linux.poll(&pf, @intCast(n_mcp + n_ai), 10);
                mcp.handle(pf[0..n_mcp]);
                ai.tick();
            }
            if (ai.busy or ai.running()) {
                say("--ai-wait: the AI is still at work after {d} ms", .{lim});
                failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--hold")) {
            // after the rest: wait to be killed (a crash for the tests)
            hold = true;
            continue;
        } else {
            say("unknown option '{s}'", .{arg});
            failed = true;
            continue;
        }
        app.frame(&canvas);
        settle();
        i += 1;
    }
    _ = app.tick();
    app.frame(&canvas);
    settle();

    // write a binary PPM, through a fixed buffer: nothing allocated at the end
    // of a session that may have used its memory up (multires.py's limit)
    const fd = try openWrite(out);
    defer _ = linux.close(fd);
    var hdr: [32]u8 = undefined;
    const hs = try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ w, h });
    try writeAll(fd, hs);
    var buf: [3 * 4096]u8 = undefined;
    var at: usize = 0;
    while (at < px.len) {
        const n: usize = @min(px.len - at, 4096);
        for (px[at .. at + n], 0..) |p, j| {
            buf[j * 3] = @truncate(p >> 16);
            buf[j * 3 + 1] = @truncate(p >> 8);
            buf[j * 3 + 2] = @truncate(p);
        }
        try writeAll(fd, buf[0 .. n * 3]);
        at += n;
    }

    if (dump) |path| {
        // the widgets of the last frame: kind, label, x y w h, enabled
        const dfd = try openWrite(path);
        defer _ = linux.close(dfd);
        var line: [160]u8 = undefined;
        for (ui.rec[0..ui.rec_n]) |*e| {
            const l = std.fmt.bufPrint(&line, "{s}\t{s}\t{d} {d} {d} {d}\t{s}\n", .{ e.kind, e.label[0..e.len], e.r.x, e.r.y, e.r.w, e.r.h, if (e.enabled) "on" else "off" }) catch continue;
            try writeAll(dfd, l);
        }
    }
    // the console's lines (tests read what a command said)
    for (args, 0..) |a2, ai| {
        if (!std.mem.eql(u8, a2, "--dump-log") or ai + 1 >= args.len) continue;
        const lfd = try openWrite(args[ai + 1]);
        defer _ = linux.close(lfd);
        var k = app.logFirst();
        while (k < app.log_count) : (k += 1) {
            try writeAll(lfd, app.logLine(k));
            try writeAll(lfd, "\n");
        }
    }
    @import("gpu.zig").stop();
    if (hold) {
        std.debug.print("held\n", .{});
        while (true) _ = linux.pause();
    }
    @import("autosave.zig").atExit(true);
    @import("ai.zig").kill();
    if (mcp_on) @import("mcp.zig").shutdown();
    mcp_on = false;
    if (failed) linux.exit_group(2);
}

fn openWrite(path_s: []const u8) !i32 {
    var pathz: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pathz, "{s}", .{path_s}, 0);
    const fd_rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd_rc) != .SUCCESS) return error.CannotWrite;
    return @intCast(fd_rc);
}

fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        off += rc;
    }
}

/// evdev code (+ shift) for an ASCII character, for --type.
fn codeFor(ch: u8) ?struct { u32, bool } {
    var code: u32 = 0;
    while (code < 64) : (code += 1) {
        if (ui.keyChar(code, false) == ch) return .{ code, false };
        if (ui.keyChar(code, true) == ch) return .{ code, true };
    }
    return null;
}
