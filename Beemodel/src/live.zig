// Rendered shading (live.s). With the GPU helper the view is livegpu.zig's; this
// is the CPU's path, without it: Hive's path tracer in a slice of each main-loop turn.
//
//   - While the view or the scene changes the viewport shows Material Preview
//     (what the original falls back to; it stands in for the GPU raycast, and
//     stays for the first few samples).
//   - LV_STILL_MS after the last change the scene goes up (only when its
//     fingerprint changed) and samples accumulate, LV_SLICE_MS a turn, up to
//     Preferences > Viewport > Rendered samples.
//   - The denoiser is too dear for every frame on the CPU: it runs when the
//     samples first show, at each doubling, and at the end.
//
// A viewport owns the live view: the one in use, else the one that has it.
// Other Rendered viewports show Material Preview. The film and the denoiser's
// buffers are the view's own, swapped in around each use: the F12 result stays
// whole (passes, save). A running F12 render owns Hive: the view pauses.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const vp = @import("viewport.zig");
const pt = @import("pt.zig");
const denoise = @import("denoise.zig");
const prefs = @import("prefs.zig");
const undo = @import("undo.zig");
const ops = @import("ops.zig");
const livegpu = @import("livegpu.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const LV_SLICE_MS = 12; // samples per turn: this much time
const LV_MIN_SPP = 4; // Material Preview shows until this many
const LV_STILL_MS = 150; // samples begin this long after the last change
pub const MAX_SAMPLES = 4096;

var film: pt.Film = .{};
var dn: denoise.State = .{};
var img: []u32 = &.{};

var owner: i16 = -1;
var drawn = false; // the owner was drawn this frame
var w: u32 = 0;
var h: u32 = 0;
var want_cam: pt.Camera = undefined;
var view_key: u64 = 0; // the camera and size wanted
var seen_scene: u64 = 0; // the scene as last drawn
var built_scene: u64 = 0; // the scene in Hive
var built_gen: u32 = 0; // pt.scene_gen of that build (F12 builds too)
var have_built = false;
var changed_at: i64 = 0;
var film_ok = false; // the film is of the view and the scene as they are
var failed = false; // out of memory: Material Preview until something changes
var running = false; // samples still to come
var stale = false; // the film has news for img
var next_dn: u32 = LV_MIN_SPP;
var dn_spp: u32 = 0; // the samples the denoised image holds
var spp: u32 = 0;
var shown_dn = false;
var film_cap: u32 = 0; // a film of so many samples (0: Rendered samples)

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn target() u32 {
    return @intCast(std.math.clamp(prefs.rendered_samples, 0, MAX_SAMPLES));
}

fn enter() void {
    pt.swapFilm(&film);
    denoise.swapState(&dn);
}
const leave = enter;

/// Everything a render depends on, not the selection: the original's
/// fingerprint (objects, meshes, lights, materials, undo steps, the edited mesh).
fn sceneHash() u64 {
    var hs = std.hash.Wyhash.init(0x6c697665);
    hs.update(std.mem.asBytes(&scene.count));
    hs.update(std.mem.asBytes(&material.version));
    hs.update(std.mem.asBytes(&pt.bounces));
    const env = @import("env.zig");
    const world = [3]u32{ env.idx, @bitCast(env.strength), @bitCast(env.rotation) };
    hs.update(std.mem.asBytes(&world));
    const steps = [2]usize{ undo.current(), undo.count() };
    hs.update(std.mem.asBytes(&steps));
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        hs.update(std.mem.asBytes(&o.kind));
        hs.update(std.mem.asBytes(&o.loc));
        hs.update(std.mem.asBytes(&o.rot));
        hs.update(std.mem.asBytes(&o.scl));
        hs.update(std.mem.asBytes(&o.color));
        hs.update(std.mem.asBytes(&o.mat));
        hs.update(std.mem.asBytes(&o.parent));
        hs.update(std.mem.asBytes(&o.mesh));
        hs.update(std.mem.asBytes(&o.light_type));
        hs.update(std.mem.asBytes(&o.light_color));
        const lf = [_]f32{ o.power, o.size, o.cone };
        hs.update(std.mem.asBytes(&lf));
        const on = [_]bool{ o.visible, o.render };
        hs.update(std.mem.asBytes(&on));
        if (@import("mods.zig").of(i)) |me| {
            hs.update(std.mem.asBytes(&me.serial));
            hs.update(std.mem.asBytes(&me.shape));
            hs.update(std.mem.asBytes(&me.verts.ptr));
            hs.update(std.mem.asBytes(&me.verts.len));
            hs.update(std.mem.asBytes(&me.tris.len));
            hs.update(std.mem.asBytes(&me.lo));
            hs.update(std.mem.asBytes(&me.hi));
        }
    }
    return hs.final();
}

fn viewKey(c: *const vp.Cam, nw: u32, nh: u32) u64 {
    var hs = std.hash.Wyhash.init(0x76696577);
    const dims = [3]u32{ nw, nh, target() };
    hs.update(std.mem.asBytes(&dims));
    hs.update(std.mem.asBytes(&c.eye));
    hs.update(std.mem.asBytes(&c.right));
    hs.update(std.mem.asBytes(&c.up));
    hs.update(std.mem.asBytes(&c.fwd));
    hs.update(std.mem.asBytes(&c.f));
    return hs.final();
}

/// The live view is drawn: lay it over the viewport's base. `r0` the viewport,
/// `r` the part of it on the canvas.
pub fn shade(cv: *gfx.Canvas, r0: Rect, r: Rect, c: *const vp.Cam, area: i16) void {
    // the viewport in use takes it: a non-viewport active leaves it where it is
    const act = app.activeArea();
    if (owner < 0 or (area == act and app.N(act).editor == .viewport)) {
        if (owner != area) view_key = 0; // (a new owner draws its own view)
        owner = area;
    }
    if (area != owner) return;
    drawn = true;
    const nw: u32 = @intCast(r0.w);
    const nh: u32 = @intCast(r0.h);
    const vk = viewKey(c, nw, nh);
    const sh = sceneHash();
    if (livegpu.frame(cv, r0, r, c, nw, nh, vk, sh)) return;
    if (vk != view_key or sh != seen_scene) {
        view_key = vk;
        seen_scene = sh;
        w = nw;
        h = nh;
        want_cam = .{ .o = c.eye, .right = c.right, .up = c.up, .fwd = c.fwd, .tan_h = @as(f32, @floatFromInt(nw)) * 0.5 / c.f };
        changed_at = wallMs();
        film_ok = false;
        running = false;
        failed = false;
        spp = 0;
        const play = playbackSamples();
        if (!motionSamples(play)) return;
        if (play > 0) running = false; // (its samples are enough: the next frame comes)
    }
    if (!film_ok or spp < minShow() or spp == 0) return;
    if (stale) {
        enter();
        defer leave();
        pt.resolve(img, .beauty, if (denoise.on and prefs.rendered_denoise) denoise.out else null);
        shown_dn = denoise.on and prefs.rendered_denoise;
        stale = false;
    }
    const bx = r.intersect(cv.clip);
    if (bx.w <= 0 or bx.h <= 0) return;
    const o0: usize = @intCast(bx.x - r0.x);
    var y: i32 = bx.y;
    while (y < bx.bottom()) : (y += 1) {
        const src = img[@as(usize, @intCast(y - r0.y)) * w + o0..][0..@intCast(bx.w)];
        const o: usize = @intCast(y * cv.w + bx.x);
        @memcpy(cv.px[o..][0..src.len], src);
    }
}

fn begin() bool {
    if (!have_built or built_scene != seen_scene or built_gen != pt.scene_gen) {
        if (!pt.buildScene()) {
            have_built = false;
            return false;
        }
        built_scene = seen_scene;
        built_gen = pt.scene_gen;
        have_built = true;
    }
    enter();
    defer leave();
    if (!pt.startFilm(w, h, if (film_cap > 0) film_cap else target(), want_cam)) {
        pt.freeFilm();
        return false;
    }
    denoise.on = false;
    dn_spp = 0;
    const n = @as(usize, w) * h;
    if (img.len != n) {
        if (img.len > 0) A.free(img);
        img = A.alloc(u32, n) catch {
            img = &.{};
            return false;
        };
    }
    return true;
}

fn denoiseIfDue(last: bool) void {
    if (!prefs.rendered_denoise or spp == 0) return;
    if (!last and spp < next_dn) return;
    if (denoise.run()) dn_spp = spp;
    next_dn = @max(spp * 2, LV_MIN_SPP);
}

/// The animation stopped: the frame it stopped on gets the view's full samples.
pub fn playbackEnded() void {
    seen_scene = 0;
    app.dirty = true;
}

/// The samples the view holds (tests).
pub fn samples() u32 {
    return spp;
}

/// Rendered playback samples: what each new frame gets while the animation
/// plays (lv_playing), 0: not playing, or none wanted.
fn playbackSamples() u32 {
    if (!@import("anim.zig").playing) return 0;
    return @intCast(std.math.clamp(prefs.rendered_playback, 0, 64));
}

/// Samples before the image shows: the few, or Rendered motion samples' own.
fn minShow() u32 {
    const p = playbackSamples();
    if (p > 0) return @min(p, target());
    const n: u32 = @intCast(std.math.clamp(prefs.rendered_motion, 0, 4));
    return @min(if (n > 0) n else LV_MIN_SPP, target());
}

/// Rendered motion samples on the CPU: that many samples of a view that just
/// changed, at once, denoised: it shows in this frame. False: none wanted or
/// none possible (the base shows, as always).
fn motionSamples(play: u32) bool {
    film_cap = play; // (playing: the film stops there, the next frame comes)
    defer film_cap = 0;
    const n: u32 = if (play > 0) play else @intCast(std.math.clamp(prefs.rendered_motion, 0, 4));
    if (n == 0 or target() == 0 or @import("render.zig").active) return false;
    if (!begin()) return false;
    film_ok = true;
    running = true;
    enter();
    defer leave();
    while (pt.minSpp() < @min(n, target())) _ = pt.tick(1000, wallMs);
    spp = pt.minSpp();
    next_dn = spp;
    denoiseIfDue(true);
    stale = true;
    return true;
}

/// The main loop's turn: ms until there is work, 0 for a next turn at once,
/// null when there is none.
pub fn tick() ?i32 {
    if (livegpu.on()) return livegpu.tick();
    if (owner < 0 or failed or target() == 0 or view_key == 0) return null;
    if (@import("render.zig").active) return null;
    // an F12 that ran out of memory took the scene with it
    if (film_ok and !pt.scene_ok) {
        film_ok = false;
        running = false;
        spp = 0;
        have_built = false;
    }
    if (!film_ok) {
        const left = changed_at + LV_STILL_MS - wallMs();
        if (left > 0) return @intCast(left);
        if (!begin()) {
            failed = true;
            app.log("  Rendered: out of memory: Material Preview meanwhile", .{});
            app.dirty = true;
            return null;
        }
        film_ok = true;
        running = true;
        next_dn = @min(LV_MIN_SPP, target());
        spp = 0;
    }
    if (!running) return null;
    enter();
    defer leave();
    running = pt.tick(LV_SLICE_MS, wallMs);
    spp = pt.minSpp();
    denoiseIfDue(!running);
    stale = true;
    app.dirty = true;
    return if (running) 0 else null;
}

/// End of a drawn frame: no viewport had the live view, its memory goes.
pub fn frameEnd() void {
    if (!drawn and owner >= 0) release();
    drawn = false;
}

fn release() void {
    livegpu.release();
    owner = -1;
    view_key = 0;
    film_ok = false;
    running = false;
    spp = 0;
    enter();
    pt.freeFilm();
    denoise.free();
    leave();
    if (img.len > 0) A.free(img);
    img = &.{};
    app.dirty = true; // (another Rendered viewport takes it over)
}

/// The line under the viewport's label: what Rendered shows.
pub fn hudLine(buf: []u8, area: i16) []const u8 {
    if (area != owner and owner >= 0) return "Rendered  |  live in another viewport";
    if (livegpu.on()) return livegpu.hudLine(buf);
    if (@import("render.zig").active) return "Rendered  |  paused: F12 is rendering";
    const t = target();
    if (!film_ok or spp == 0 or spp < minShow()) return "Rendered  |  Material Preview";
    const dnd: []const u8 = if (shown_dn) ", denoised" else "";
    if (spp >= t) return std.fmt.bufPrint(buf, "Rendered  |  {d} samples{s}", .{ spp, dnd }) catch "Rendered";
    return std.fmt.bufPrint(buf, "Rendered  |  {d} / {d} samples{s}", .{ spp, t, dnd }) catch "Rendered";
}

/// Headless: the view to its last sample (after a frame drew it).
pub fn finish() void {
    if (livegpu.finish()) return;
    changed_at = -LV_STILL_MS;
    while (tick()) |_| {
        changed_at = -LV_STILL_MS;
    }
}

// --- operators -------------------------------------------------------------------------

/// view.rendered_samples <n>
pub fn opSamples() void {
    const t = std.mem.trim(u8, ops.arg, " \"");
    const x = @import("expr.zig").eval(t) orelse return app.log("  view.rendered_samples <0 .. {d}>", .{MAX_SAMPLES});
    if (!std.math.isFinite(x)) return app.log("  view.rendered_samples <0 .. {d}>", .{MAX_SAMPLES});
    prefs.rendered_samples = @intFromFloat(std.math.clamp(@round(x), 0, MAX_SAMPLES));
    prefs.save();
    app.log("  Rendered samples: {d}", .{prefs.rendered_samples});
    app.dirty = true;
}

fn setInt(comptime name: []const u8, v: *i32, hi: i32) void {
    const t = std.mem.trim(u8, ops.arg, " \"");
    const x = @import("expr.zig").eval(t) orelse return app.log("  " ++ name ++ " <0 .. {d}>", .{hi});
    if (!std.math.isFinite(x)) return app.log("  " ++ name ++ " <0 .. {d}>", .{hi});
    v.* = @intFromFloat(std.math.clamp(@round(x), 0, @as(f32, @floatFromInt(hi))));
    prefs.save();
    app.log("  " ++ name ++ ": {d}", .{v.*});
    app.dirty = true;
}

/// view.rendered_motion <0..4>: samples a frame while the view moves (0: the raycast).
pub fn opMotion() void {
    setInt("view.rendered_motion", &prefs.rendered_motion, 4);
}

/// view.rendered_playback <0..64>: samples a frame while the animation plays.
pub fn opPlayback() void {
    setInt("view.rendered_playback", &prefs.rendered_playback, 64);
}

/// view.rendered_denoise [0|1]: none: on or off.
pub fn opDenoise() void {
    const t = std.mem.trim(u8, ops.arg, " \"");
    if (t.len == 0) prefs.rendered_denoise = !prefs.rendered_denoise else {
        const x = @import("expr.zig").eval(t) orelse return app.log("  view.rendered_denoise [0|1]", .{});
        prefs.rendered_denoise = x != 0;
    }
    prefs.save();
    denoiseChanged();
}

/// The preference moved: a finished view shows it at once.
pub fn denoiseChanged() void {
    if (film_ok and spp > 0) {
        // (a denoise of fewer samples is not this image's)
        if (prefs.rendered_denoise and dn_spp != spp) {
            enter();
            defer leave();
            if (denoise.run()) dn_spp = spp;
        }
        stale = true;
    }
    app.dirty = true;
}

pub fn isDenoise() bool {
    return prefs.rendered_denoise;
}
