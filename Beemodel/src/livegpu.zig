// Rendered shading on the GPU (live.s): the helper draws the view from the scene
// Hive snapshots, kept in a slot of its own (pt.comp's live flags):
//   - while the view or the scene changes: one raycast a frame (the lights' direct
//     light with hard shadows, the sky with short-range occlusion, mirrors and
//     glass followed); or, with Rendered motion samples 1 .. 4, that many
//     path-traced samples a frame, denoised (the bounced light while moving);
//   - when it is still: Hive's samples, accumulated on the GPU, a slice of time a
//     turn, up to Rendered samples (the raycast shows for the first few), denoised
//     on the GPU unless Rendered denoise is off (pt.comp's dn_ stages);
//   - while the animation plays: each new frame's scene goes up at once and gets
//     Rendered playback samples, denoised, more while the frame stays (0: the raycast).
//
// The scene goes up again when its fingerprint (live.zig) changes: every change
// when it builds quickly, else once the change is over (the view stays live on the
// last snapshot). A running F12 render owns Hive: the view keeps what it has.
//
// Never a wait on the helper past a short slice: runs are sent, their replies
// polled for in the frame (so a quick raycast shows at once) and in the main
// loop's turns; a run for a view that has moved on is dropped when it comes back.
// When the helper is lost the view goes on on the CPU (live.zig).
const std = @import("std");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const vp = @import("viewport.zig");
const pt = @import("pt.zig");
const gpu = @import("gpu.zig");
const gp = @import("gpupt.zig");
const ipc = @import("gpu/ipc.zig");
const prefs = @import("prefs.zig");
const editors = @import("editors.zig");
const render = @import("render.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const LV_SLICE_MS = 12; // samples per turn: this much time
const LV_MIN_SPP = 4; // the raycast shows until this many
const LV_BATCH_MAX = 64;
const LV_QUICK_MS = 30; // builds this quick follow every change
const LV_STILL_MS = 150; // samples begin this long after a build
const LV_DN_STAGES = 6; // the variance, five a-trous passes
const FRAME_WAIT_MS = 10; // a frame waits this much for what it asked
const SLOT = ipc.SLOT_LIVE;

const F_LIVE: u32 = 1;
const F_RAY: u32 = 2;
const F_DN: u32 = 4;

const State = enum { none, raycast, samples };
const Op = union(enum) { none, ray, trace: u32, samples: u32, dn: u32 };

var active = false; // the last owner's frame went this way
var gen_lost: u32 = 0;
var ok = false; // the scene is up for w x h
var w: u32 = 0;
var h: u32 = 0;
var hash: u64 = 0; // the scene that went up
var seen: u64 = 0; // the last frame's
var view_key: u64 = 0;
var cam: pt.Camera = undefined;
var state: State = .none;
var op: Op = .none;
var op_view: u32 = 0; // the view an op was sent for
var view_gen: u32 = 0;
var sent_at: i64 = 0;
var built_at: i64 = -100000;
var build_ms: i64 = 0;
var need_build = false;
var unfit: u64 = 0; // this scene cannot go (live.zig's CPU path has it)
var spp: u32 = 0;
var batch: u32 = 1;
var dn = false; // the samples carry the denoiser's sums
var shown_dn = false;
var shown_spp: u32 = 0;
var img: []u32 = &.{}; // what shows: XRGB
var img_w: u32 = 0;
var img_h: u32 = 0;
var img_view: u32 = 0; // the view (view_gen) the image is of
var img_fresh = false;
var next_show: u32 = 0; // the denoised image is made again at this many samples
var failed_mem = false;
var last_sh: u64 = 0;

// gpu(7 ..): what render.device says. A frame's time runs from the run's sending
// to its pixels in hand: the raycast, or a moving frame's samples with their denoise.
pub var nray: u32 = 0;
pub var nput: u32 = 0;
pub var ray_us: i64 = 0;
pub var dn_us: i64 = 0;
var dn_t0: i64 = 0;
var frame_t0: i64 = 0;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn nowUs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn target() u32 {
    return @intCast(std.math.clamp(prefs.rendered_samples, 0, 4096));
}

fn dnWant() bool {
    return prefs.rendered_denoise;
}

/// Samples a frame while playing, 0: not playing or the raycast.
fn playing() u32 {
    if (!@import("anim.zig").playing) return 0;
    return @intCast(std.math.clamp(prefs.rendered_playback, 0, 64));
}

fn moving() u32 {
    return @intCast(std.math.clamp(prefs.rendered_motion, 0, 4));
}

/// This frame's GPU: up, or on its way.
fn available() bool {
    if (gpu.device == .cpu or failed_mem) return false;
    _ = gpu.ready(0);
    return gpu.isUp() or gpu.isStarting();
}

fn dropAll() void {
    ok = false;
    state = .none;
    op = .none;
    spp = 0;
    need_build = false;
    gp.ups[SLOT] = .{};
}

/// The live view's memory goes (no Rendered viewport).
pub fn release() void {
    active = false;
    dropAll();
    view_key = 0;
    if (img.len > 0) A.free(img);
    img = &.{};
    img_w = 0;
    img_h = 0;
    img_fresh = false;
}

/// The last frame went this way: live.zig's turn and line are ours.
pub fn on() bool {
    return active;
}

fn blit(cv: *gfx.Canvas, r0: Rect, r: Rect) void {
    const bx = r.intersect(cv.clip);
    if (bx.w <= 0 or bx.h <= 0) return;
    const o0: usize = @intCast(bx.x - r0.x);
    var y: i32 = bx.y;
    while (y < bx.bottom()) : (y += 1) {
        const src = img[@as(usize, @intCast(y - r0.y)) * img_w + o0..][0..@intCast(bx.w)];
        const o: usize = @intCast(y * cv.w + bx.x);
        @memcpy(cv.px[o..][0..src.len], src);
    }
}

fn takePixels() void {
    const px = gp.pixels(SLOT) orelse return;
    if (img.len != px.len) {
        if (img.len > 0) A.free(img);
        img = A.alloc(u32, px.len) catch {
            img = &.{};
            return;
        };
    }
    @memcpy(img, px);
    img_w = w;
    img_h = h;
    img_view = view_gen;
    img_fresh = true;
    app.dirty = true;
}

/// The scene goes up, or sent again at a new size. False: stay on the CPU.
fn build() bool {
    need_build = false;
    const t0 = nowMs();
    // (an F12 render owns Hive: its snapshot, as it stands)
    if (!render.active and !pt.buildScene()) return false;
    if (!gp.liveFits()) {
        unfit = last_sh;
        return false;
    }
    if (!gp.put(SLOT, w, h, true)) {
        if (gpu.isUp()) failed_mem = true;
        return false;
    }
    build_ms = nowMs() - t0;
    built_at = nowMs();
    hash = last_sh;
    ok = true;
    nput += 1;
    restart();
    return true;
}

fn restart() void {
    state = .none;
    spp = 0;
    batch = 1;
    next_show = 0;
    view_gen +%= 1;
}

const O_PIX: u32 = 1 << ipc.B_M2;

fn send(next: Op, flags: u32, first: u32, count: u32, outs: u32) bool {
    if (!gp.run(SLOT, flags, first, count, &cam, outs)) return false;
    op = next;
    op_view = view_gen;
    sent_at = nowMs();
    if (next == .ray or next == .trace) frame_t0 = nowUs();
    return true;
}

fn shows() bool {
    return spp >= @min(LV_MIN_SPP, @max(target(), 1));
}

var moving_frame = false;

fn frameDone() void {
    if (moving_frame) ray_us = nowUs() - frame_t0;
    moving_frame = false;
}

/// The op that came back.
fn finishOp() void {
    const o = op;
    op = .none;
    const took = nowMs() - sent_at;
    if (op_view != view_gen) return; // (for a view that has moved on)
    switch (o) {
        .none => {},
        .ray => {
            takePixels();
            ray_us = nowUs() - frame_t0;
            nray += 1;
            state = .raycast;
            shown_spp = 0;
            shown_dn = false;
        },
        .trace, .samples => |n| {
            spp += n;
            state = .samples;
            if (o == .samples) {
                if (took * 4 < LV_SLICE_MS) batch = @min(batch * 2, LV_BATCH_MAX) else if (took > LV_SLICE_MS and batch > 1) batch /= 2;
            } else {
                nray += 1;
                moving_frame = true;
            }
            if (!shows()) return;
            // The denoiser costs more than a sample: while the view refines
            // it runs when half as many samples again are in, and at the end.
            if (o == .samples and dn and spp < target() and spp < next_show) return;
            next_show = spp + @max(1, spp / 2);
            if (dn) {
                dn_t0 = nowUs();
                _ = send(.{ .dn = 1 }, F_LIVE | F_DN | (1 << 8), spp, 0, 0);
            } else {
                takePixels();
                shown_spp = spp;
                shown_dn = false;
                frameDone();
            }
        },
        .dn => |k| {
            if (k < LV_DN_STAGES) {
                _ = send(.{ .dn = k + 1 }, F_LIVE | F_DN | ((k + 1) << 8), spp, 0, if (k + 1 == LV_DN_STAGES) O_PIX else 0);
                return;
            }
            takePixels();
            dn_us = nowUs() - dn_t0;
            shown_spp = spp;
            shown_dn = true;
            frameDone();
        },
    }
}

/// The image is of the view and the scene as they are now.
fn haveImage() bool {
    return img_fresh and img_view == view_gen and state != .none;
}

/// What to do next: true when a run went out.
fn nextOp() bool {
    if (need_build and !gpu.busy()) {
        if (!build()) return false;
    }
    if (!ok or need_build) return false;
    const want = dnWant();
    if (dn != want) {
        dn = want;
        restart();
    }
    const dnf = if (dn) F_DN else 0;
    const play = playing();
    if (state == .none) {
        const n = if (play > 0) play else moving();
        if (n > 0) return send(.{ .trace = n }, F_LIVE | dnf, 0, n, if (dn) 0 else O_PIX);
        return send(.ray, F_LIVE | F_RAY, 0, 0, O_PIX);
    }
    const t = target();
    if (spp >= t and spp > 0) return false;
    if (t == 0) return false;
    if (play == 0 and nowMs() - built_at < LV_STILL_MS) return false;
    const n = @min(batch, t - spp);
    return send(.{ .samples = n }, F_LIVE | dnf, spp, n, if (dn) 0 else O_PIX);
}

/// Runs for at most budget ms. `for_frame`: a frame's wait, over as soon as
/// the view it draws has its image (what refines it is sent, not waited for).
fn step(budget: i32, for_frame: bool) void {
    const t0 = nowMs();
    while (true) {
        if (op != .none or gpu.busy()) {
            if (for_frame and haveImage()) return;
            const left: i64 = @as(i64, budget) - (nowMs() - t0);
            if (left < 0 or !gpu.runWait(@intCast(left))) return;
            if (!gpu.isUp()) return;
            if (op != .none) {
                finishOp();
                continue;
            }
        }
        if (!nextOp()) return;
        if (nowMs() - t0 >= budget) return;
    }
}

/// The scene's fingerprint against what went up: when it goes again.
fn policy(sh: u64) void {
    last_sh = sh;
    if (!ok) {
        need_build = true;
    } else if (sh != hash and !render.active) {
        const t = nowMs();
        if (sh == seen or playing() > 0 or (build_ms <= LV_QUICK_MS and t - built_at >= build_ms)) need_build = true;
    }
    seen = sh;
}

/// The frame: lay the GPU's image over the viewport's base. False: this view
/// is the CPU's (live.zig goes on as it does without a helper).
pub fn frame(cv: *gfx.Canvas, r0: Rect, r: Rect, c: *const vp.Cam, nw: u32, nh: u32, vk: u64, sh: u64) bool {
    if (!available() or sh == unfit) {
        if (active) dropAll();
        active = false;
        return false;
    }
    if (!active) gen_lost = gpu.lost;
    if (gpu.lost != gen_lost) {
        gen_lost = gpu.lost;
        dropAll();
        active = false;
        return false;
    }
    active = true;
    if (nw != w or nh != h) {
        w = nw;
        h = nh;
        ok = false;
        if (op != .none) view_gen +%= 1;
    }
    if (vk != view_key) {
        view_key = vk;
        cam = .{ .o = c.eye, .right = c.right, .up = c.up, .fwd = c.fwd, .tan_h = @as(f32, @floatFromInt(nw)) * 0.5 / c.f };
        restart();
    }
    if (!gpu.isUp()) {
        // on its way: the base (Material Preview) meanwhile
        last_sh = sh;
        return true;
    }
    policy(sh);
    step(FRAME_WAIT_MS, true);
    if (gpu.lost != gen_lost or !gpu.isUp()) {
        return frameLost();
    }
    if (img.len > 0 and img_w == nw and img_h == nh) blit(cv, r0, r);
    return true;
}

fn frameLost() bool {
    gen_lost = gpu.lost;
    dropAll();
    active = false;
    app.log("  Rendered: the GPU failed: the CPU from here on", .{});
    app.dirty = true;
    return false;
}

fn more() bool {
    if (op != .none or need_build) return true;
    if (!ok) return false;
    if (state == .none) return true;
    const t = target();
    return t > 0 and spp < t;
}

/// The main loop's turn: as live.zig's.
pub fn tick() ?i32 {
    if (!active) return null;
    if (gpu.isStarting()) {
        gpu.pump(0);
        if (gpu.isUp() or !gpu.isStarting()) app.dirty = true;
        return 5;
    }
    if (!gpu.isUp() or gpu.lost != gen_lost) {
        _ = frameLost();
        return null;
    }
    // the change is over: a frame to see it with
    if (last_sh != hash and !render.active) app.dirty = true;
    step(LV_SLICE_MS, false);
    if (!gpu.isUp()) return null;
    if (!more() and last_sh == hash) return null;
    if (state != .none and spp == 0 and op == .none) {
        const left = built_at + LV_STILL_MS - nowMs();
        if (left > 0) return @intCast(left);
    }
    return if (op != .none) 1 else 0;
}

/// Headless: the view to its last sample. False: not this way.
pub fn finish() bool {
    if (!active) return false;
    if (gpu.isStarting()) _ = gpu.ready(15000);
    if (!gpu.isUp()) return false;
    built_at = -100000;
    policy(last_sh);
    var guard: u32 = 0;
    while (guard < 2000000) : (guard += 1) {
        step(100, false);
        if (!gpu.isUp()) return false;
        built_at = -100000;
        if (!more()) break;
    }
    return true;
}

/// The line under the viewport's label: what Rendered shows.
pub fn hudLine(buf: []u8) []const u8 {
    if (!gpu.isUp()) return "Rendered  |  starting the GPU";
    const t = target();
    const dnd: []const u8 = if (shown_dn) ", denoised" else "";
    if (shown_spp == 0) return "Rendered  |  raycast";
    if (shown_spp >= t) return std.fmt.bufPrint(buf, "Rendered  |  {d} samples{s}", .{ shown_spp, dnd }) catch "Rendered";
    return std.fmt.bufPrint(buf, "Rendered  |  {d} / {d} samples{s}", .{ shown_spp, t, dnd }) catch "Rendered";
}
