// The Render window (render.s): F12 renders the scene progressively into a
// Render area (made beside the 3D viewport when there is none); the main
// loop spends a slice of every turn on more samples (tick), so the UI stays
// live, and Esc stops. The Render area shows the chosen pass fit to it (the
// wheel zooms about the pointer, a drag pans, Home fits); render.save writes
// any pass as PNG.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const vp = @import("viewport.zig");
const pt = @import("pt.zig");
const hive = @import("hive.zig");
const ops = @import("ops.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const SLICE_MS = 14; // rendering per main-loop turn
const HEAD = 26; // the editor's status line

// render settings (kept in .bee: RNDR)
pub var width: u32 = 960;
pub var height: u32 = 540;
pub var samples: u32 = 128;
pub var denoise: bool = true;
pub var pass: pt.Pass = .beauty;
var shutter: f32 = 0; // (motion blur, sample reuse: kept for the file)
var reuse: u32 = 0;

pub fn resetSettings() void {
    // (Preferences > Rendering: new scenes')
    const pp = @import("prefpages.zig");
    width = @intCast(pp.render_w);
    height = @intCast(pp.render_h);
    samples = @intCast(pp.render_spp);
    denoise = pp.render_dn;
    pass = .beauty;
    shutter = 0;
    reuse = 0;
}

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// RNDR, as the original's rndr_read: bad sizes keep the defaults.
pub fn readSettings(d: []const u8) void {
    if (d.len < 16) return;
    const w = rd32(d, 0);
    const h = rd32(d, 4);
    const s = rd32(d, 8);
    if (w -% 1 >= 8192 or h -% 1 >= 8192 or s -% 1 >= 65536) return;
    width = w;
    height = h;
    samples = s;
    pass = @enumFromInt(rd32(d, 12) & 3);
    if (d.len >= 20) denoise = rd32(d, 16) & 1 != 0;
    if (d.len >= 24) {
        const f: f32 = @bitCast(rd32(d, 20));
        shutter = if (f > 0) @min(f, 1) else 0;
    }
    if (d.len >= 28) reuse = @min(rd32(d, 24), 16);
}

pub fn writeSettings(out: *std.ArrayList(u8), a: std.mem.Allocator) void {
    const v = [7]u32{ width, height, samples, @intFromEnum(pass), @intFromBool(denoise), @bitCast(shutter), reuse };
    for (v) |x| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, x, .little);
        out.appendSlice(a, &b) catch {
            @import("bee.zig").encode_failed = true;
        };
    }
}

pub var active = false;
var have = false;
var t0: i64 = 0;
var t_ms: i64 = 0;
var img: []u32 = &.{};
var stale = false;
// the Render area's view: zoom over the fit, pan of the image's centre from the box's
/// The Render editor's view of the image (zoom, pan: Zui's image view).
var view: zui.View2D = .{};
/// The image as Zui draws it, over `img` (not copied).
var zimg: zui.Image = undefined;
var zimg_for: []u32 = &.{};

pub var now_fn: *const fn () i64 = defaultNow;
fn defaultNow() i64 {
    return app.now_ms;
}

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// The camera that renders: the scene's camera object (looking down its
/// -Z), else the 3D viewport's view; tan of half the horizontal angle.
fn camera() pt.Camera {
    if (vp.sceneCamera()) |ci| {
        const o = &scene.objects[ci];
        const wt = scene.worldTRS(ci);
        const R = m.eulerMat(wt.rot);
        return .{
            .o = wt.loc,
            .right = m.norm(.{ R[0], R[3], R[6] }),
            .up = m.norm(.{ R[1], R[4], R[7] }),
            .fwd = m.norm(.{ -R[2], -R[5], -R[8] }),
            .tan_h = 18.0 / @max(o.lens, 1),
        };
    }
    const vi = app.viewportArea();
    const v: vp.View = if (view_over) |o| o.* else if (vi >= 0) app.N(vi).view else .{};
    const c = vp.Cam.init(&v, .{ .w = @intCast(width), .h = @intCast(height) });
    // (a file render's view: hv_camera's fixed 50 mm lens, tan 39.6 / 2)
    if (view_over != null) return .{ .o = c.eye, .right = c.right, .up = c.up, .fwd = c.fwd, .tan_h = 0.35993 };
    // the view's vertical angle, the render's width
    return .{ .o = c.eye, .right = c.right, .up = c.up, .fwd = c.fwd, .tan_h = @as(f32, @floatFromInt(width)) * 0.5 / c.f };
}

/// The camera as a frame of an animation sees it.
pub fn frameCamera() pt.Camera {
    return camera();
}

/// An animation takes the film: the Render area's samples are gone (render_abort).
pub fn abandon() void {
    active = false;
    have = false;
}

pub fn start() void {
    stop(false);
    if (!pt.start(width, height, samples, camera())) {
        app.log("  render: out of memory", .{});
        pt.freeFilm();
        return;
    }
    if (img.len != @as(usize, width) * height) {
        if (img.len > 0) A.free(img);
        img = A.alloc(u32, @as(usize, width) * height) catch {
            img = &.{};
            app.log("  render: out of memory", .{});
            return;
        };
    }
    @memset(img, 0x202020);
    @import("denoise.zig").on = false;
    active = true;
    have = true;
    stale = true;
    t0 = wallMs();
    t_ms = 0;
    const ra = app.ensureRenderArea();
    if (ra >= 0) app.setActiveArea(ra);
    const gp = @import("gpupt.zig");
    // (headless runs wait for the helper's hello; the window a moment at most)
    const on_gpu = gp.begin(if (@import("files.zig").headless) 15000 else 500);
    if (on_gpu) {
        app.log("  rendering {d} x {d} px, {d} samples, on the {s} (Esc stops)", .{ width, height, samples, gp.whereShort() });
    } else if (gp.why == .no_helper) {
        app.log("  rendering {d} x {d} px, {d} samples, on the CPU ({d} threads) (Esc stops)", .{ width, height, samples, @import("jobs.zig").count() });
    } else {
        app.log("  rendering {d} x {d} px, {d} samples, on the CPU ({d} threads): {s} (Esc stops)", .{ width, height, samples, @import("jobs.zig").count(), gp.why.text() });
    }
    if (hive.tris.len == 0) app.log("  render: the scene has no meshes to render (the sky alone)", .{});
    app.dirty = true;
}

fn stop(say: bool) void {
    if (!active) return;
    active = false;
    @import("gpupt.zig").stop();
    t_ms = wallMs() - t0;
    stale = true;
    denoiseNow();
    if (say) {
        app.log("  render stopped: {d} samples, {d:.1} s", .{ pt.minSpp(), @as(f64, @floatFromInt(t_ms)) / 1000 });
        app.toast(.ok, "Render stopped: {d} samples", .{pt.minSpp()});
    }
}

/// Esc / render.stop: keeps the samples so far.
pub fn stopNow() void {
    stop(true);
    app.dirty = true;
}

/// The main loop's turn: more samples for a slice of time. True while rendering.
pub fn tick() bool {
    if (!active) return false;
    const more = @import("gpupt.zig").turn(SLICE_MS, wallMs);
    stale = true;
    t_ms = wallMs() - t0;
    if (!more) {
        active = false;
        denoiseNow();
        app.log("  render finished: {d} samples, {d:.1} s", .{ pt.minSpp(), @as(f64, @floatFromInt(t_ms)) / 1000 });
        app.toast(.ok, "render finished: {d} samples, {d:.1} s", .{ pt.minSpp(), @as(f64, @floatFromInt(t_ms)) / 1000 });
    }
    app.dirty = true;
    return active;
}

/// Headless: render to the end (tests).
pub fn finish() void {
    while (tick()) {}
}

/// The view a file render looks through when there is no camera (null: the viewport's).
var view_over: ?*const vp.View = null;

/// hive_render_file: the scene to a PNG, w x h, spp samples, denoised when
/// asked, through the scene's camera or the view given (the library's
/// thumbnails; a child process of its own). False: not written.
pub fn renderFile(path: []const u8, w: u32, h: u32, spp: u32, dn: bool, v: *const vp.View) bool {
    const keep = .{ width, height, samples, denoise, pass };
    defer {
        width = keep[0];
        height = keep[1];
        samples = keep[2];
        denoise = keep[3];
        pass = keep[4];
        view_over = null;
    }
    width = w;
    height = h;
    samples = spp;
    denoise = dn;
    pass = .beauty;
    view_over = v;
    start();
    finish();
    if (!have or pt.fw == 0) return false;
    const data = encodeImage(path, .beauty) orelse return false;
    defer A.free(data);
    if (!@import("files.zig").mayWrite(path)) return false;
    @import("bee.zig").writeAtomic(path, data) catch return false;
    return true;
}

/// A finished or stopped render gets denoised (when wanted).
fn denoiseNow() void {
    if (denoise) _ = @import("denoise.zig").run();
}

fn denoised() ?[][4]f32 {
    const dn = @import("denoise.zig");
    return if (dn.on and !active) dn.out else null;
}

fn resolve() void {
    if (!stale or !have or pt.fw == 0) return;
    if (img.len != @as(usize, pt.fw) * pt.fh) return;
    pt.resolve(img, pass, if (pass == .beauty) denoised() else null);
    // (opaque, for Zui's image)
    for (img) |*p| p.* |= 0xff000000;
    if (zimg_for.ptr == img.ptr and zimg_for.len == img.len) zimg.touch();
    stale = false;
}

/// How far the running render is (for its chip).
pub fn progress() @import("jobui.zig").Progress {
    var done: u64 = 0;
    for (pt.row_spp) |s| done += s;
    const all = @as(u64, pt.target) * @max(pt.fh, 1);
    return .{ .label = "Rendering the image", .frac = @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(@max(all, 1))), .ms = wallMs() - t0 };
}

pub fn pollRender() ?[]const u8 {
    return if (!have) "No render yet (F12 renders)" else null;
}
pub fn pollRendering() ?[]const u8 {
    return if (!active) "No render running" else null;
}

// --- operators -------------------------------------------------------------------------

const Words = struct {
    it: std.mem.TokenIterator(u8, .any),
    fn init(s: []const u8) Words {
        return .{ .it = std.mem.tokenizeAny(u8, s, " \"") };
    }
};

fn parsePass(nm: []const u8) ?pt.Pass {
    var lb: [16]u8 = undefined;
    if (nm.len > lb.len) return null;
    return std.meta.stringToEnum(pt.Pass, std.ascii.lowerString(&lb, nm));
}

pub fn opStart() void {
    start();
}
pub fn opStop() void {
    stopNow();
}

pub fn opPass() void {
    var w = Words.init(ops.arg);
    if (w.it.next()) |nm| {
        pass = parsePass(nm) orelse return app.log("  render pass: beauty, albedo, normal or depth", .{});
        stale = true;
        app.log("  render pass: {s}", .{@tagName(pass)});
        return;
    }
    pass = @enumFromInt((@intFromEnum(pass) + 1) % 4);
    stale = true;
    app.log("  render pass: {s}", .{@tagName(pass)});
}

pub fn opSettings() void {
    var w = Words.init(ops.arg);
    var v: [3]u32 = .{ width, height, samples };
    var k: usize = 0;
    while (w.it.next()) |t| : (k += 1) {
        if (k >= 3) break;
        const x = @import("expr.zig").eval(t) orelse return app.log("  render.settings <width> <height> <samples>", .{});
        if (!std.math.isFinite(x)) return app.log("  render.settings <width> <height> <samples>", .{});
        const hi: f32 = if (k == 2) 65536 else 8192;
        v[k] = @intFromFloat(std.math.clamp(@round(x), 1, hi));
    }
    width = v[0];
    height = v[1];
    samples = v[2];
    app.log("  render settings: {d} x {d}, {d} samples", .{ width, height, samples });
}

/// render.device [auto|rtx|gpu|cpu]: where renders run; none: what there is.
pub fn opDevice() void {
    const gpu = @import("gpu.zig");
    const gp = @import("gpupt.zig");
    var w = Words.init(ops.arg);
    if (w.it.next()) |t| {
        var lb: [16]u8 = undefined;
        if (t.len > lb.len) return app.log("  render.device [auto|rtx|gpu|cpu]", .{});
        const d = gpu.parseDevice(std.ascii.lowerString(&lb, t)) orelse return app.log("  render.device [auto|rtx|gpu|cpu]", .{});
        setDevice(d);
        return;
    }
    if (gpu.device != .cpu) _ = gpu.ready(if (@import("files.zig").headless) 15000 else 0);
    app.log("  render device: {s}; helper: {s}{s}", .{ gpu.device.label(), if (gpu.isUp()) gpu.deviceName() else "none", if (gpu.hasRtx()) " (RTX)" else "" });
    app.log("  last render: {s}{s}{s}; {d} GPU runs, {d} ms; {d} KiB sent", .{ gp.whereShort(), if (gp.why.text().len > 0) ": " else "", gp.why.text(), gpu.total_runs, gpu.total_ms, gp.last_kib });
    const gv = @import("gview.zig");
    const rs = @import("gpuraster.zig");
    app.log("  viewport: {d} frames on the GPU ({d:.1} ms the last), {d} KiB of meshes; raster: {d} batches, {d} on the CPU; shared memory {s}", .{ gv.nframes, @as(f64, @floatFromInt(gv.last_us)) / 1000, gv.mesh_kib, rs.nbatch, rs.nfall, if (gpu.hostMem()) "imported" else "copied" });
    const lg = @import("livegpu.zig");
    app.log("  Rendered: {d} raycasts ({d:.1} ms the last), {d} scene uploads, denoise {d:.1} ms", .{ lg.nray, @as(f64, @floatFromInt(lg.ray_us)) / 1000, lg.nput, @as(f64, @floatFromInt(lg.dn_us)) / 1000 });
}

pub fn setDevice(d: @import("gpu.zig").Device) void {
    const gpu = @import("gpu.zig");
    gpu.device = d;
    @import("prefs.zig").render_device = @intFromEnum(d);
    @import("prefs.zig").save();
    app.log("  render device: {s}", .{d.label()});
    app.dirty = true;
}

/// The Render tab's line: the GPU found, where the last render ran.
pub fn deviceLine(b: []u8) []const u8 {
    const gpu = @import("gpu.zig");
    const gp = @import("gpupt.zig");
    if (gp.why == .none) {
        if (gpu.isUp()) return std.fmt.bufPrint(b, "GPU: {s}{s}", .{ gpu.deviceName(), if (gpu.hasRtx()) " (RTX)" else "" }) catch "";
        return if (gpu.device == .cpu) "The CPU, every core" else "No GPU helper: the CPU, every core";
    }
    if (gp.why == .gpu) return std.fmt.bufPrint(b, "Last render: on the {s}", .{gp.whereShort()}) catch "";
    return std.fmt.bufPrint(b, "Last render: on the CPU ({s})", .{gp.why.text()}) catch "";
}

pub fn opDenoise() void {
    denoise = !denoise;
    // a finished render shows it either way at once
    if (have and !active) {
        if (denoise) denoiseNow() else @import("denoise.zig").on = false;
        stale = true;
    }
    app.log("  denoise: {s}", .{if (denoise) "on" else "off"});
}
pub fn isDenoise() bool {
    return denoise;
}

pub fn opFit() void {
    view = .{}; // (it fits the image again)
    app.dirty = true;
}

/// render.save <path> [pass]: PNG (other passes than the shown one too).
fn savePicked(p: []const u8) void {
    saveTo(p, pass);
}

pub fn opSave() void {
    var w = Words.init(ops.arg);
    const path = w.it.next() orelse {
        // from a menu or button: where to
        @import("filebrowser.zig").show(.save, "Save Render", ".png", "render.png", savePicked);
        return;
    };
    var p = pass;
    if (w.it.next()) |nm| p = parsePass(nm) orelse return app.log("  render pass: beauty, albedo, normal or depth", .{});
    saveTo(path, p);
}

/// The pass as a file: .exr keeps the linear floats, else PNG.
fn encodeImage(path: []const u8, p: pt.Pass) ?[]u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".exr")) {
        const rgb = A.alloc([3]f32, @as(usize, pt.fw) * pt.fh) catch return null;
        defer A.free(rgb);
        pt.linear(rgb, p, if (p == .beauty) denoised() else null);
        return @import("exr.zig").encode(A, pt.fw, pt.fh, rgb) catch null;
    }
    const px = A.alloc(u32, @as(usize, pt.fw) * pt.fh) catch return null;
    defer A.free(px);
    pt.resolve(px, p, if (p == .beauty) denoised() else null);
    return @import("png.zig").encode(A, pt.fw, pt.fh, px) catch null;
}

pub fn saveTo(path0: []const u8, p: pt.Pass) void {
    if (!have or pt.fw == 0) return app.log("  render: no image yet (F12 renders)", .{});
    const files = @import("files.zig");
    var pb: [1024]u8 = undefined;
    const path = files.expandHome(&pb, path0) orelse return app.log("  render: could not write the file", .{});
    const data = encodeImage(path, p) orelse return app.log("  render: out of memory", .{});
    defer A.free(data);
    if (!files.mayWrite(path)) return app.log("  render: not written (tests write under /tmp only): {s}", .{path});
    @import("bee.zig").writeAtomic(path, data) catch return app.log("  render: could not write the file", .{});
    app.log("  render saved: {s}", .{path});
    app.toast(.ok, "Render saved: {s}", .{std.fs.path.basename(path)});
}

// --- the Render editor ------------------------------------------------------------------

pub fn header(i: i16, r: Rect) void {
    // centred in the header's free part (as the original)
    const w = 58 + 4 + 66;
    const z = host.beginPart("render.head", @intCast(i), .{ .x = r.x + @max(0, @divTrunc(r.w - w, 2)), .y = r.y + 2, .w = w, .h = r.h - 4 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 4 });
    defer z.endHorizontal();
    const rb = z.button("Render", .{ .width = .px(58), .height = .px(@floatFromInt(r.h - 4)), .variant = .selected });
    z.tooltipRich(rb, .{ .title = "Render", .shortcut = "F12", .body = "Render the scene" });
    if (rb.clicked) start();
    const sb = z.button("Settings", .{ .width = .px(66), .height = .px(@floatFromInt(r.h - 4)), .variant = .flat });
    z.tooltipRich(sb, .{ .title = "Settings", .body = "Show every render setting: the Properties' Render tab" });
    if (sb.clicked) app.showRenderSettings();
}

fn passLabel(p: pt.Pass) []const u8 {
    return switch (p) {
        .beauty => "Beauty",
        .albedo => "Albedo",
        .normal => "Normal",
        .depth => "Depth",
    };
}

/// The result: the status line, then the image (Zui's image view: the
/// wheel zooms about the pointer, a middle drag pans, Home fits).
pub fn body(i: i16, r: Rect) void {
    const th = ui.th;
    const z = host.beginPart("render", @intCast(i), r) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.pane_bg) });
    z.beginVertical(.{ .width = .fill, .height = .fill, .padding = 8, .spacing = 4 });
    defer z.endVertical();
    if (!have or pt.fw == 0) {
        z.label("Press F12 to render the scene", .{});
        ui.record("info", "Press F12 to render the scene", host.rectOf(z.lastRect()), true);
        z.label("(camera object, or the viewport's view)", .{ .color = host.col(th.text_dim) });
        return;
    }
    resolve();
    // the status line: "960 x 540   12 / 128 samples   1.4 s   Beauty"
    var b: [96]u8 = undefined;
    const st = std.fmt.bufPrint(&b, "{d} x {d}   {d} / {d} samples   {s}   {d:.1} s   ", .{ pt.fw, pt.fh, pt.minSpp(), pt.target, @import("gpupt.zig").whereShort(), @as(f64, @floatFromInt(if (active) wallMs() - t0 else t_ms)) / 1000 }) catch "";
    var b2: [40]u8 = undefined;
    const tail = std.fmt.bufPrint(&b2, "{s}{s}", .{ passLabel(pass), if (pass == .beauty and denoised() != null) "   denoised" else "" }) catch "";
    var b3: [140]u8 = undefined;
    const line = std.fmt.bufPrint(&b3, "{s}{s}", .{ st, tail }) catch st;
    z.label(line, .{ .width = .fill });
    ui.record("info", line, host.rectOf(z.lastRect()), true);
    if (img.len != @as(usize, pt.fw) * pt.fh) return;
    if (!(zimg_for.ptr == img.ptr and zimg_for.len == img.len)) {
        zimg = .initArgb(img, pt.fw, pt.fh);
        zimg.is_opaque = true;
        zimg_for = img;
    }
    const f = z.imageView("##render image", &zimg, &view, .{ .background = host.col(th.pane_bg) });
    ui.record("image", "render", host.rectOf(f.rectToScreen(.{ .w = @floatFromInt(pt.fw), .h = @floatFromInt(pt.fh) }).intersect(f.rect)), true);
    _ = z.endView2D();
}
