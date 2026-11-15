// Play mode (play.s): walk or fly through the scene while it runs.
//
// F5 (play.start) snapshots the scene and plays from the viewport's eye:
//
// walk  a capsule (0.3 m radius, 1.75 m tall, eyes at 1.6) under the
//       rigid-body world's gravity, moved and slid along every mesh's
//       triangles: each tick (fixed 1/120 s steps) it moves, then up to five
//       times takes the deepest contact and leaves it (a contact facing up
//       under 50 degrees is ground; walls and ceilings take the velocity into
//       them away). Blocked on the ground, it tries the move again 0.4 m
//       higher and comes back down onto the step; on the ground it follows
//       slopes down. Space jumps, Shift runs.
// fly   free, no collisions; Space up, C down, Shift faster. F switches.
//
// WASD move, the mouse looks (captured: the compositor's locked pointer and
// relative motion when it has them). The scene's frame runs with the clock,
// so keys, rigid bodies and cloth play live, and the logic graphs
// (logic.zig) with them. Esc stops and asks: K keeps the changes (one undo
// step), D or Esc discards them (the scene, its frame and the camera as they
// were). While playing the undo history stands still: what the scene does is
// play, not edits.
//
// Each mesh gets a grid of its triangles in its own space the first time the
// capsule comes near; queries take the capsule's box into that space and test
// the triangles found there in world space. Every float is the original's:
// its SSE operations lane by lane in its order, its x87 sines, cosines,
// arctangent and cube root, so the player walks where the original's does,
// bit for bit.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const logic = @import("logic.zig");
const nt = @import("ntree.zig");
const A = std.heap.page_allocator;

pub const V = @Vector(4, f32);

pub var radius: f32 = 0.3;
pub var height: f32 = 1.75;
const eye_h: f32 = 1.6;
const step_h: f32 = 0.4;
pub var walk_speed: f32 = 4.0;
pub var run_speed: f32 = 8.0;
pub var fly_speed: f32 = 8.0;
const flyrun: f32 = 24.0;
pub var jump: f32 = 5.0;
const ground_cos: f32 = 0.64; // 50 degrees
const DT: f32 = 0.0083333333; // 1/120
const look_k: f32 = 0.0025;

const IN_FWD = 1;
const IN_BACK = 2;
const IN_LEFT = 4;
const IN_RIGHT = 8;
const IN_UP = 16;
const IN_RUN = 32;
const IN_DOWN = 64;

// the player's frame: its X, up, Z
var RX: V = .{ 1, 0, 0, 0 };
var up: V = .{ 0, 1, 0, 0 };
var RZ: V = .{ 0, 0, 1, 0 };
var pk: V = @splat(0); // (a turn: its axis, cos and sin)
var pcs: [2]f32 = .{ 0, 0 };
var gacc: V = @splat(0); // the pull where it stands
var pos: V = @splat(0); // feet
var vel: V = @splat(0);
var start: V = @splat(0);
/// 0 off, 1 playing, 2 asking
pub var on: u32 = 0;
/// 1 walk, 2 fly
pub var mode: u32 = 0; // (pl_mode: 0 until play starts; 1 walk, 2 fly)
var keys: u32 = 0;
var ground: bool = false;
var wall: bool = false;
var snap: scene.State = .{ .count = 0, .active = null, .cursor = .{ 0, 0, 0 }, .render_camera = null };
var cam: @import("viewport.zig").Pose = .{};
var cam_area: i16 = -1;
/// The camera's yaw and pitch (radians), as the original's cam_yaw, cam_pitch.
var yaw: f32 = 0;
var pitch: f32 = 0;
var yaw0: f32 = 0; // (as they were: a discard gives them back)
var pitch0: f32 = 0;
var frame0: f32 = 1;
var frame_was: f32 = 1;
var time: f32 = 0; // seconds played
var acc: f32 = 0; // time not yet stepped
var best_d: f32 = 0;
var best_n: V = @splat(0);
var best_obj: u32 = 0;
var cur_obj: u32 = 0;
var gobj: u32 = 0; // the object stood on, where it was
var gground: u32 = 0;
var gloc: [3]f32 = .{ 0, 0, 0 };
var t_last: i64 = 0;
var lastx: i32 = -100000;
var lasty: i32 = 0;
var haspos = false;
var locked = false;
var stamp: u32 = 0;
var steps: u32 = 0;
var pair_s: V = @splat(0);
var pair_t: V = @splat(0);
var mat: [12]f32 = undefined; // an object's matrix
var inv: [12]f32 = undefined; //  and its inverse
var tri: [3]V = undefined; // a triangle in world space
var box0: V = @splat(0);
var box1: V = @splat(0);

/// What logic.zig reads of the player.
pub const State = struct { on: u32, pos: V, radius: f32, height: f32 };
pub fn state() State {
    return .{ .on = on, .pos = pos, .radius = radius, .height = height };
}

// --- SSE, lane by lane ---------------------------------------------------------------------

const XYZ: @Vector(4, bool) = .{ true, true, true, false };
fn andXyz(v: V) V {
    return @select(f32, XYZ, v, @as(V, @splat(0)));
}
fn sp(x: f32) V {
    return @splat(x);
}
fn neg3(v: V) V {
    const s: @Vector(4, u32) = .{ 0x80000000, 0x80000000, 0x80000000, 0 };
    return @bitCast(@as(@Vector(4, u32), @bitCast(v)) ^ s);
}
fn minps(a: V, b: V) V {
    return @select(f32, a < b, a, b);
}
fn maxps(a: V, b: V) V {
    return @select(f32, a > b, a, b);
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
/// dpps 0x7f / 0x71: (x x' + y y') + (z z' + 0)
fn dot(a: V, b: V) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + 0.0);
}
/// dpps 0xf1: all four lanes
fn dot4(a: V, b: V) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + p[3]);
}
/// PCROSS d, a, b: a x b as the original's shuffles give it
fn cross(a: V, b: V) V {
    return .{ b[2] * a[1] - a[2] * b[1], b[0] * a[2] - a[0] * b[2], b[1] * a[0] - a[1] * b[0], b[3] * a[3] - a[3] * b[3] };
}
/// cross45: a.yzx b.zxy - a.zxy b.yzx (masked)
fn cross45(a: V, b: V) V {
    return andXyz(.{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0], 0 });
}

// --- the x87, as the original computes ------------------------------------------------------

const use_x87 = @import("builtin").cpu.arch == .x86_64;
// fld dword [rdi]; fld dword [rdi+4]; fpatan; fstp dword [rdi]; ret
export const bee_x87_patan32: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0x47, 0x04, 0xd9, 0xf3, 0xd9, 0x1f, 0xc3 };
// fld dword [rdi]; fld1; fxch; fyl2x; fdiv dword [rdi+4]; fld st0; frndint;
// fsub st1, st0; fxch; f2xm1; fld1; faddp; fscale; fstp st1; fstp dword [rdi]; ret
export const bee_x87_cbrt32: [32]u8 linksection(".text") = .{
    0xd9, 0x07, 0xd9, 0xe8, 0xd9, 0xc9, 0xd9, 0xf1, 0xd8, 0x77, 0x04, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc,
    0xe9, 0xd9, 0xc9, 0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xd9, 0x1f, 0xc3,
};

fn run87(code: []const u8, a: f32, b: f32) f32 {
    var m: [2]f32 = .{ a, b };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&m);
    return m[0];
}
/// fpatan: atan2(y, x), rounded to f32 from the x87's.
fn atan2f(y: f32, x: f32) f32 {
    if (!use_x87) return std.math.atan2(y, x);
    return run87(&bee_x87_patan32, y, x);
}
/// 2^(log2(x) / 3) through the x87, as pl_grid.
fn cbrtf(x: f32) f32 {
    if (!use_x87) return std.math.pow(f32, 2, std.math.log2(x) / 3);
    return run87(&bee_x87_cbrt32, x, 3);
}
const sincos = @import("animexpr.zig").sincos32;

// --- the operators ----------------------------------------------------------------------------

fn view() ?*@import("viewport.zig").View {
    const a = app.viewportArea();
    if (a < 0) return null;
    cam_area = a;
    return &app.N(a).view;
}

/// view_eye: the viewport camera's eye (target + its way back times the distance).
fn viewEye() V {
    const v = view() orelse return @splat(0);
    const sy = sincos(yaw);
    const spp = sincos(pitch);
    return .{
        spp[1] * sy[0] * v.dist + v.target[0],
        spp[0] * v.dist + v.target[1],
        spp[1] * sy[1] * v.dist + v.target[2],
        0,
    };
}

/// play.start [walk|fly] [x y z]
fn opStart() void {
    if (on != 0) return;
    mode = 1;
    var w = nt.Words{ .s = ops.arg };
    var rest = w;
    const first = w.next();
    if (first.len > 0) {
        if (first[0] == 'f') {
            mode = 2;
            rest = w;
        }
        // x y z (words that are not numbers: skipped)
        var k: usize = 0;
        var xyz: [3]f32 = .{ start[0], start[1], start[2] };
        while (k < 3) {
            const s = rest.next();
            if (s.len == 0) break;
            const x = nt.parseFloat(s, null) orelse continue;
            xyz[k] = x;
            k += 1;
        }
        start = .{ xyz[0], xyz[1], xyz[2], start[3] };
        if (k >= 3) haspos = true;
    }
    begin();
}

fn begin() void {
    // the scene as it is now; the camera, the frame
    scene.save(&snap);
    if (view()) |v| {
        cam = v.pose();
        yaw = v.yaw * @import("math.zig").deg;
        pitch = v.pitch * @import("math.zig").deg;
    }
    yaw0 = yaw;
    pitch0 = pitch;
    const an = @import("anim.zig");
    frame_was = an.frame;
    frame0 = an.frame;
    if (!haspos) start = viewEye();
    haspos = false;
    var p = start;
    if (mode != 2) p = p - V{ 0, eye_h, 0, 0 }; // (walking: the feet below the eye)
    pos = andXyz(p);
    start = pos;
    vel = @splat(0);
    keys = 0;
    ground = false;
    time = 0;
    acc = 0;
    steps = 0;
    gobj = 0;
    frameReset(); // (up: the world's, until pulled round)
    gacc = @splat(0);
    @import("rbody.zig").live(true); // simulations live, the logic graphs
    logic.beginPlay();
    t_last = app.now_ms;
    on = 1;
    @import("undo.zig").frozen = true;
    locked = lockPointer();
    lastx = -100000;
    camera();
    app.log("{s}", .{if (mode == 2) "  play: fly (Esc stops)" else "  play: walk (Esc stops)"});
    app.dirty = true;
}

/// play.stop [keep|discard]
fn opStop() void {
    if (on == 0) return;
    var w = nt.Words{ .s = ops.arg };
    end(std.mem.eql(u8, w.next(), "keep"));
}

/// play_end: keep (one undo step), or discard (the scene, its frame, the camera as they were).
pub fn end(kept: bool) void {
    on = 0;
    keys = 0;
    unlockPointer();
    locked = false;
    freeGrids();
    logic.endPlay();
    @import("rbody.zig").live(false);
    const undo = @import("undo.zig");
    undo.frozen = false;
    if (kept) {
        undo.strokeStep("Play", null);
        app.log("  play: changes kept (Ctrl+Z undoes them)", .{});
    } else {
        scene.load(&snap);
        @import("anim.zig").apply(frame_was);
        yaw = yaw0;
        pitch = pitch0;
        if (cam_area >= 0 and app.areaValid(cam_area) and app.N(cam_area).editor == .viewport) app.N(cam_area).view.setPose(cam);
        app.log("  play: changes discarded", .{});
    }
    app.dirty = true;
}

/// play.mode walk|fly
fn opMode() void {
    var w = nt.Words{ .s = ops.arg };
    const s = w.next();
    if (s.len == 0) return;
    mode = if (s[0] == 'f') 2 else 1;
    vel = @splat(0);
}

// --- input -------------------------------------------------------------------------------------

/// play_key (every key, pressed or released): true when play mode takes it.
pub fn key(code: u32, pressed: bool) bool {
    if (on == 0) return false;
    if (on == 1) logic.key(code, pressed);
    const K = @import("ui.zig").KEY;
    if (on == 2) { // asking: K keeps, D / Esc discard
        if (!pressed) return true;
        if (code == 37) end(true) else if (code == 32 or code == K.ESC) end(false);
        return true;
    }
    if (code == K.ESC) {
        if (!pressed) return true;
        on = 2; // stopped: the question
        keys = 0;
        unlockPointer();
        locked = false;
        app.dirty = true;
        return true;
    }
    if (code == 33) { // F: walk <-> fly
        if (!pressed) return true;
        mode ^= 3;
        vel = @splat(0);
        return true;
    }
    const b: u32 = switch (code) {
        17 => IN_FWD,
        31 => IN_BACK,
        30 => IN_LEFT,
        32 => IN_RIGHT,
        57 => IN_UP,
        42 => IN_RUN,
        46, 29 => IN_DOWN,
        else => 0,
    };
    if (pressed) keys |= b else keys &= ~b;
    return true;
}

/// play_look: the mouse turns the view (pixels).
pub fn look(dx: f32, dy: f32) void {
    if (on != 1) return;
    yaw = yaw - dx * look_k;
    pitch = minss(maxss(pitch + dy * look_k, -1.5), 1.5);
    app.dirty = true;
}

/// play_motion: without a locked pointer the pointer's movement turns the view.
pub fn motion(x: i32, y: i32) bool {
    if (on == 0) return false;
    if (on != 1 or locked) return true;
    const ox = lastx;
    const oy = lasty;
    lastx = x;
    lasty = y;
    if (ox == -100000) return true;
    look(@floatFromInt(x -% ox), @floatFromInt(y -% oy));
    camera();
    return true;
}

/// The window's locked pointer (wnd_lock_pointer, wnd_unlock_pointer): set by
/// the window when the compositor has pointer constraints and relative motion.
pub var lock_fn: ?*const fn () bool = null;
pub var unlock_fn: ?*const fn () void = null;
fn lockPointer() bool {
    return if (lock_fn) |f| f() else false;
}
fn unlockPointer() void {
    if (unlock_fn) |f| f();
}

// --- the tick ------------------------------------------------------------------------------------

/// play_tick (the main loop): the time since the last tick, the player moved in
/// fixed steps, the scene's frame on. The ms until the next tick, null: not playing.
pub fn tick() ?i32 {
    if (on != 1) return null;
    const now = app.now_ms;
    const ms = now - t_last;
    t_last = now;
    const s = minss(@as(f32, @floatFromInt(ms)) / 1000.0, 0.1);
    advance(s);
    return 8;
}

/// pl_advance: fixed steps for that time (with what is left from before), the frame, the camera.
fn advance(s: f32) void {
    acc = s + acc;
    while (acc >= DT) {
        acc = acc - DT;
        time = time + DT;
        step();
        steps +%= 1;
        logic.step(DT); // the logic graphs, the same step
    }
    const fps = @import("frange.zig").r.fps;
    @import("anim.zig").apply(fps * time + frame0); // the scene's frame: by the clock
    camera();
    app.dirty = true;
}

// --- the player's frame: its up follows the pull where it stands --------------------------------

fn frameReset() void {
    RX = .{ 1, 0, 0, 0 };
    up = .{ 0, 1, 0, 0 };
    RZ = .{ 0, 0, 1, 0 };
}

/// pl_to_world: x y z in the player's frame -> the world.
fn toWorld(v: V) V {
    return andXyz((sp(v[0]) * RX + sp(v[1]) * up) + sp(v[2]) * RZ);
}

/// pl_basis (the viewport's camera while playing): right, up, fwd turned into
/// the player's frame. Null when there is nothing to turn.
pub fn basis(v: [3]f32) ?[3]f32 {
    if (on != 1) return null;
    const r = toWorld(.{ v[0], v[1], v[2], 0 });
    return .{ r[0], r[1], r[2] };
}

/// pl_rot: v turned by pk, pcs (Rodrigues).
fn rot(v: V) V {
    const kv = cross(pk, v) * sp(pcs[1]);
    const d = dot(pk, v);
    const kd = sp(d) * sp(1.0 - pcs[0]) * pk;
    return andXyz((v * sp(pcs[0]) + kv) + kd);
}

/// pl_unit
fn unit(v: V) V {
    const l = maxss(dot(v, v), 1.0e-4);
    return andXyz(v / sp(@sqrt(l)));
}

/// pl_turn: the frame turned towards t (unit), at most 0.05 rad a step, kept orthonormal.
fn turn(t: V) void {
    var k = andXyz(cross(up, t));
    var s = @sqrt(dot(k, k));
    const c = dot(up, t);
    if (!(s > 1.0e-4)) {
        if (c > 0) return; // parallel: done; opposite: about X
        k = RX;
        s = 1.0;
    }
    pk = k / sp(s);
    const ang = minss(atan2f(s, c), 0.05);
    const scv = sincos(ang);
    pcs = .{ scv[1], scv[0] };
    RX = rot(RX);
    up = rot(up);
    up = unit(up);
    RZ = unit(cross(RX, up));
    RX = unit(cross(up, RZ));
}

/// pl_down: the pull where the player stands (the force fields and gravity at its
/// middle, else the world's gravity); its up turns against it.
fn down() void {
    const fl = @import("fields.zig");
    const g = @import("rbody.zig").gravity();
    var a: V = .{ g[0], g[1], g[2], 0 };
    fl.prep(time, .{ g[0], g[1], g[2] });
    if (fl.n != 0) {
        const mid = sp(height * 0.5) * up + pos;
        const f = fl.accel(.{ mid[0], mid[1], mid[2] }, .{ vel[0], vel[1], vel[2] }, 1, false);
        a = .{ f[0], f[1], f[2], 0 };
    }
    gacc = a;
    if (!(dot(a, a) > 1.0e-4)) return; // (nothing pulls: up stays)
    turn(neg3(unit(a)));
}

/// pl_vup: (v . up) up and v . up
fn vup(v: V) struct { V, f32 } {
    const d = dot(v, up);
    return .{ sp(d) * up, d };
}
/// pl_vup2: v without its part along up
fn vup2(v: V) V {
    return v - sp(dot(v, up)) * up;
}

/// pl_camera: the viewport's camera at the player's eyes (its frame).
fn camera() void {
    var eye = pos;
    if (mode != 2) eye = eye + sp(eye_h) * up;
    const sy = sincos(yaw);
    const spp = sincos(pitch);
    const f = neg3(.{ spp[1] * sy[0], spp[0], spp[1] * sy[1], 0 });
    const t = toWorld(f) * sp(0.05) + eye;
    const v = view() orelse return;
    v.target = .{ t[0], t[1], t[2] };
    v.dist = 0.05;
    setViewAngles(v);
    v.gliding = false;
}

/// pl_wish: the velocity the keys ask for (walk: along the ground, in the
/// player's frame; fly: where it looks, and its up).
fn wish() V {
    const sy = sincos(yaw); // sin, cos
    const spp = sincos(pitch);
    var f: f32 = 0;
    var r: f32 = 0;
    var u: f32 = 0;
    if (keys & IN_FWD != 0) f = f + 1;
    if (keys & IN_BACK != 0) f = f - 1;
    if (keys & IN_RIGHT != 0) r = r + 1;
    if (keys & IN_LEFT != 0) r = r - 1;
    if (keys & IN_UP != 0) u = u + 1;
    if (keys & IN_DOWN != 0) u = u - 1;
    var speed = walk_speed;
    if (mode == 2) {
        speed = if (keys & IN_RUN != 0) flyrun else fly_speed;
    } else if (keys & IN_RUN != 0) speed = run_speed;
    var v: V = undefined;
    if (mode != 2) {
        v = .{ sy[1] * r - sy[0] * f, 0, 0 - (sy[1] * f + sy[0] * r), 0 };
    } else {
        v = .{ sy[1] * r - spp[1] * sy[0] * f, (0 - spp[0] * f) + u, 0 - (spp[1] * sy[1] * f + sy[0] * r), 0 };
    }
    v = andXyz(v);
    const l = dot(v, v);
    if (l > 1.0e-4) v = v / sp(@sqrt(l)) * sp(speed);
    return toWorld(v);
}

const dt4: V = .{ DT, DT, DT, 0 };

/// pl_step: one fixed step.
fn step() void {
    const w = wish();
    if (mode == 2) { // fly: as asked, no collisions
        vel = w;
        pos = w * dt4 + pos;
        return;
    }
    ride(); // (on something that moved: along)
    down(); // the pull here; up against it
    const vu = vup(vel)[0]; // walk: along the ground as asked, along up by the pull
    const flat = vup2(w);
    vel = flat + vu;
    if (ground and keys & IN_UP != 0) { // jump: up at its speed
        vel = flat + sp(jump) * up;
        ground = false;
    }
    vel = gacc * dt4 + vel; // the pull
    const was_ground = ground;
    pos = vel * dt4 + pos;
    resolve();
    if (was_ground and wall) tryStep(); // blocked on the ground: a step?
    if (was_ground and !ground) { // walked off down a slope: kept on it
        if (!(vup(vel)[1] > 0)) snapDown();
    }
    rideMark(); // what it stands on now, and where
    if (!(pos[1] >= -1000.0)) { // fell out of the world: back
        pos = start;
        vel = @splat(0);
        frameReset();
    }
}

/// pl_ride: standing on an object that moved since the last step: along with it.
fn ride() void {
    if (!ground or gobj == 0) return;
    const i = scene.findOid(gobj) orelse return;
    const l = scene.objects[i].loc;
    pos = andXyz(V{ l[0], l[1], l[2], 0 } - V{ gloc[0], gloc[1], gloc[2], 0 }) + pos;
}

/// pl_ride_mark: after the step, the object stood on and its place.
fn rideMark() void {
    gobj = 0;
    if (!ground) return;
    gobj = gground;
    const i = scene.findOid(gobj) orelse {
        gobj = 0;
        return;
    };
    gloc = scene.objects[i].loc;
}

/// pl_resolve: up to five times the deepest contact left (in the player's frame).
fn resolve() void {
    ground = false;
    wall = false;
    for (0..5) |_| {
        contact();
        if (!(best_d > 0)) return;
        logic.touch(best_obj); // (logic: the player touched it)
        var d = best_d + 0.001;
        const n = best_n;
        const nu = dot(n, up);
        if (nu >= ground_cos) { // ground: straight up
            d = d / nu;
            pos = sp(d) * up + pos;
            ground = true;
            gground = best_obj;
            const x = vup(vel);
            if (!(x[1] >= 0)) vel = vel - x[0];
        } else if (!(nu > -0.7)) { // a ceiling: along it
            pos = sp(d) * n + pos;
            const x = vup(vel);
            if (x[1] > 0) vel = vel - x[0];
        } else { // a wall: sideways
            wall = true;
            var nh = andXyz(n - sp(nu) * up);
            const l = @sqrt(dot(nh, nh));
            d = d / maxss(l, 0.2);
            nh = nh / maxps(sp(l), sp(1.0e-4));
            pos = nh * sp(d) + pos;
            const vn = dot(vel, nh);
            if (!(vn >= 0)) vel = vel - sp(vn) * nh;
        }
    }
}

/// pl_try_step: (blocked) the step again from 0.4 m higher, then down onto what is
/// there: kept when it lands on ground.
fn tryStep() void {
    const p0 = pos;
    const v0 = vel;
    ok: {
        var f = andXyz(vup2(wish())); // the move asked for, flat: at least the radius on
        const l = dot(f, f);
        if (!(l > 1.0e-4)) break :ok;
        f = f / sp(@sqrt(l));
        f = f * sp(radius * 1.2);
        const rise = sp(step_h) * up;
        pos = (p0 + rise) + f;
        resolve();
        if (wall) break :ok; // still a wall up there: too tall
        pos = pos - rise;
        resolve();
        if (!ground or wall) break :ok;
        const x = vup(pos - p0); // higher than before: a step taken
        if (!(x[1] > 0.05)) break :ok;
        pos = x[0] + p0;
        vel = vup2(v0);
        ground = true;
        return;
    }
    pos = p0;
    vel = v0;
    ground = true;
}

/// pl_snap_down: down up to 0.25 m onto ground below, else as it was.
fn snapDown() void {
    const p0 = pos;
    pos = pos - sp(0.25) * up;
    resolve();
    if (!ground) pos = p0;
}

// --- contacts: the capsule against every mesh's triangles ----------------------------------------

/// pl_contact: best_d, best_n: the deepest the capsule goes into a triangle (0: none).
fn contact() void {
    best_d = 0;
    const r = sp(radius);
    const a = r * up + pos;
    const b = sp(height - radius) * up + pos;
    box0 = andXyz(minps(a, b) - r);
    box1 = andXyz(maxps(a, b) + r);
    const mods = @import("mods.zig");
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        cur_obj = o.oid;
        if (!o.kind.isMesh() or !o.visible) continue;
        const me = mods.of(i) orelse continue;
        if (me.tris.len == 0) continue;
        mat = @import("fields.zig").objMatrix(i);
        if (!invert()) continue;
        const q = boxLocal(); // the box in its space
        const lo: V = .{ me.lo[0], me.lo[1], me.lo[2], 0 };
        const hi: V = .{ me.hi[0], me.hi[1], me.hi[2], 0 };
        var out = false;
        inline for (0..3) |c| {
            if (hi[c] < q[0][c] or q[1][c] < lo[c]) out = true;
        }
        if (out) continue;
        const g = grid(me) orelse continue;
        stamp +%= 1;
        const c0 = cellOf(g, q[0]);
        const c1 = cellOf(g, q[1]);
        var z = c0[2];
        while (z <= c1[2]) : (z += 1) {
            var y = c0[1];
            while (y <= c1[1]) : (y += 1) {
                var x = c0[0];
                while (x <= c1[0]) : (x += 1) {
                    const ci: usize = @intCast((@as(i64, g.n[1]) * z + y) * g.n[0] + x);
                    for (g.ent[g.off[ci]..g.off[ci + 1]]) |t| {
                        if (g.stamp[t] == stamp) continue;
                        g.stamp[t] = stamp;
                        triWorld(me, t);
                        capTri();
                    }
                }
            }
        }
    }
}

/// pl_invert: inv = the inverse of mat (false: singular).
fn invert() bool {
    const m = &mat;
    const c00 = m[5] * m[10] - m[6] * m[9];
    const c01 = m[6] * m[8] - m[4] * m[10];
    const c02 = m[4] * m[9] - m[5] * m[8];
    const det = (m[0] * c00 + m[1] * c01) + m[2] * c02;
    if (!(@abs(det) > 1.0e-8)) return false;
    const id = 1.0 / det;
    inv[0] = c00 * id;
    inv[4] = c01 * id;
    inv[8] = c02 * id;
    inv[1] = (m[2] * m[9] - m[1] * m[10]) * id;
    inv[5] = (m[0] * m[10] - m[2] * m[8]) * id;
    inv[9] = (m[1] * m[8] - m[0] * m[9]) * id;
    inv[2] = (m[1] * m[6] - m[2] * m[5]) * id;
    inv[6] = (m[2] * m[4] - m[0] * m[6]) * id;
    inv[10] = (m[0] * m[5] - m[1] * m[4]) * id;
    for (0..3) |r| {
        const s = (inv[r * 4] * m[3] + inv[r * 4 + 1] * m[7]) + inv[r * 4 + 2] * m[11];
        inv[r * 4 + 3] = 0 - s;
    }
    return true;
}

/// xform: the point through a 3x4 matrix (w taken as 1).
fn xform(mt: *const [12]f32, p0: V) V {
    const p: V = .{ p0[0], p0[1], p0[2], 1 };
    return .{
        dot4(p, .{ mt[0], mt[1], mt[2], mt[3] }),
        dot4(p, .{ mt[4], mt[5], mt[6], mt[7] }),
        dot4(p, .{ mt[8], mt[9], mt[10], mt[11] }),
        0,
    };
}

/// box_local: the query box's corners in inv's space.
fn boxLocal() [2]V {
    var lo: V = .{ 1.0e30, 1.0e30, 1.0e30, 0 };
    var hi: V = .{ -1.0e30, -1.0e30, -1.0e30, 0 };
    for (0..8) |c| {
        var p = box0;
        if (c & 1 != 0) p[0] = box1[0];
        if (c & 2 != 0) p[1] = box1[1];
        if (c & 4 != 0) p[2] = box1[2];
        const q = xform(&inv, p);
        lo = minps(lo, q);
        hi = maxps(hi, q);
    }
    return .{ lo, hi };
}

/// tri_world: triangle t's corners in world space.
fn triWorld(me: *const scene.Mesh, t: u32) void {
    for (0..3) |c| {
        const v = me.verts[me.tris[t][c]];
        tri[c] = xform(&mat, .{ v[0], v[1], v[2], 0 });
    }
}

var d2: f32 = 0; // (cap_tri: the closest distance squared so far)

fn keepPair(on_tri: V, on_axis: V) void {
    const d = on_axis - on_tri;
    const x = dot(d, d);
    if (x < d2) {
        d2 = x;
        pair_t = on_tri;
        pair_s = on_axis;
    }
}

/// cap_tri: the capsule against tri: the closest points between its axis and the
/// triangle; deeper than best_d: kept.
fn capTri() void {
    const a = pos + sp(radius) * up; // its axis: along the player's up
    const b = a + sp((height - radius) - radius) * up;
    d2 = 1.0e30;
    var n = cross45(tri[1] - tri[0], tri[2] - tri[0]);
    const l = dot(n, n);
    if (!(l > 1.0e-8)) return; // (no area)
    n = n / sp(@sqrt(l));
    const s = dot((a + b) * V{ 0.5, 0.5, 0.5, 0 } - tri[0], n);
    if (!(s >= 0)) n = neg3(n);
    keepPair(ptTri(a), a);
    keepPair(ptTri(b), b);
    for (0..3) |e| {
        const ss = segSeg(a, b, tri[e], tri[(e + 1) % 3]);
        keepPair(ss[1], ss[0]);
    }
    // the axis through the face: out along the normal, past its end behind
    const da = dot(a - tri[0], n);
    const db = dot(b - tri[0], n);
    var depth: f32 = undefined;
    var nrm: V = undefined;
    through: {
        if (da * db >= 0) break :through;
        const t = da / (da - db);
        const x = (b - a) * sp(t) + a;
        const p = ptTri(x);
        const dx = x - p;
        if (dot(dx, dx) > 1.0e-4) break :through;
        depth = (0 - minss(da, db)) + radius; // inside: r + the end behind
        nrm = n;
        return keep(depth, nrm);
    }
    if (!(d2 < 1.0e30)) return;
    depth = radius - @sqrt(d2); // else: r - the distance
    nrm = n; // (touching: the face normal)
    if (d2 > 1.0e-4) {
        const v = andXyz(pair_s - pair_t);
        nrm = v / sp(@sqrt(dot(v, v)));
    }
    keep(depth, nrm);
}

fn keep(depth: f32, n: V) void {
    if (depth > best_d) {
        best_d = depth;
        best_n = n;
        best_obj = cur_obj;
    }
}

/// pt_tri: the point of tri closest to p (Ericson).
fn ptTri(p: V) V {
    const a = tri[0];
    const b = tri[1];
    const c = tri[2];
    const ab = b - a;
    const ac = c - a;
    const ap = p - a;
    const d1 = dot(ab, ap);
    const d2_ = dot(ac, ap);
    if (!(d1 > 0) and !(d2_ > 0)) return a;
    const bp = p - b;
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);
    if (d3 >= 0 and !(d4 > d3)) return b;
    const vc = d1 * d4 - d3 * d2_;
    if (!(vc > 0) and d1 >= 0 and !(d3 > 0)) return a + ab * sp(d1 / (d1 - d3));
    const cp = p - c;
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);
    if (d6 >= 0 and !(d5 > d6)) return c;
    const vb = d5 * d2_ - d1 * d6;
    if (!(vb > 0) and d2_ >= 0 and !(d6 > 0)) return a + ac * sp(d2_ / (d2_ - d6));
    const va = d3 * d6 - d5 * d4;
    const e43 = d4 - d3;
    const e56 = d5 - d6;
    if (!(va > 0) and e43 >= 0 and e56 >= 0) return b + (c - b) * sp(e43 / (e56 + e43));
    const id = 1.0 / ((va + vb) + vc);
    return (a + ab * sp(vb * id)) + ac * sp(vc * id);
}

fn clamp01(x: f32) f32 {
    return minss(maxss(x, 0), 1);
}

/// seg_seg: the closest points on the first and the second segment (Ericson).
fn segSeg(p1: V, q1: V, p2: V, q2: V) [2]V {
    const e1 = q1 - p1;
    const e2 = q2 - p2;
    const r = p1 - p2;
    const a = dot(e1, e1);
    const e = dot(e2, e2);
    const f = dot(e2, r);
    var s: f32 = 0;
    var t: f32 = 0;
    if (!(a > 1.0e-8)) {
        t = if (e > 1.0e-8) clamp01(f / e) else 0;
    } else {
        const c = dot(e1, r);
        if (!(e > 1.0e-8)) {
            t = 0;
            s = clamp01((0 - c) / a);
        } else {
            const bb = dot(e1, e2);
            const den = a * e - bb * bb;
            if (den > 1.0e-8) s = clamp01((bb * f - c * e) / den);
            t = (bb * s + f) / e;
            if (!(t >= 0)) {
                t = 0;
                s = clamp01((0 - c) / a);
            } else if (t > 1) {
                t = 1;
                s = clamp01((bb - c) / a);
            }
        }
    }
    return .{ (r + p2) + e1 * sp(s), p2 + e2 * sp(t) };
}

// --- a mesh's grid of triangles (its own space) ------------------------------------------------

const Grid = struct {
    me: *const scene.Mesh,
    serial: u32,
    shape: u32,
    n: [3]i32, // cells x, y, z
    cell: f32,
    off: []u32,
    ent: []u32,
    stamp: []u32,
};
const PC_MAX = 256;
const PG_CAP = 128;
var grids: [PC_MAX]Grid = undefined;
var ngrids: u32 = 0;

/// pl_grid: the mesh's grid (made the first time; null: no room).
fn grid(me: *const scene.Mesh) ?*Grid {
    for (grids[0..ngrids]) |*g| {
        if (g.me == me and g.serial == me.serial and g.shape == me.shape) return g;
    }
    if (ngrids >= PC_MAX) return null;
    const g = &grids[ngrids];
    // cells: about the cube root of the triangles a side, along the longest
    const nt_: u32 = @intCast(me.tris.len);
    var k = cbrtf(@floatFromInt(@as(i32, @bitCast(nt_))));
    k = minss(maxss(k, 1), 128);
    var size = andXyz(V{ me.hi[0], me.hi[1], me.hi[2], 0 } - V{ me.lo[0], me.lo[1], me.lo[2], 0 });
    size = maxps(size, sp(1.0e-4));
    var longest = maxss(size[1], size[0]);
    longest = maxss(longest, size[2]);
    const cell = longest / k;
    var n: [3]i32 = undefined;
    inline for (0..3) |c| {
        const q = size[c] / cell;
        var x: u32 = @bitCast(cvttps(q));
        x +%= 1;
        if (x > PG_CAP) x = PG_CAP;
        n[c] = @intCast(x);
    }
    const cells: usize = @intCast(n[0] * n[1] * n[2]);
    g.* = .{ .me = me, .serial = me.serial, .shape = me.shape, .n = n, .cell = cell, .off = &.{}, .ent = &.{}, .stamp = &.{} };
    g.off = A.alloc(u32, cells + 1) catch return null;
    @memset(g.off, 0);
    var t: u32 = 0;
    while (t < nt_) : (t += 1) { // count
        const b = triCells(g, t);
        var z = b[2];
        while (z <= b[5]) : (z += 1) {
            var y = b[1];
            while (y <= b[4]) : (y += 1) {
                var x = b[0];
                while (x <= b[3]) : (x += 1) g.off[@intCast((n[1] * z + y) * n[0] + x)] += 1;
            }
        }
    }
    var sum: u32 = 0; // counts -> first entries
    for (g.off) |*o| {
        const c = o.*;
        o.* = sum;
        sum += c;
    }
    g.ent = A.alloc(u32, sum + 1) catch {
        A.free(g.off);
        return null;
    };
    g.stamp = A.alloc(u32, nt_ + 1) catch {
        A.free(g.off);
        A.free(g.ent);
        return null;
    };
    @memset(g.stamp, 0);
    t = 0;
    while (t < nt_) : (t += 1) { // fill
        const b = triCells(g, t);
        var z = b[2];
        while (z <= b[5]) : (z += 1) {
            var y = b[1];
            while (y <= b[4]) : (y += 1) {
                var x = b[0];
                while (x <= b[3]) : (x += 1) {
                    const ci: usize = @intCast((n[1] * z + y) * n[0] + x);
                    g.ent[g.off[ci]] = t;
                    g.off[ci] += 1;
                }
            }
        }
    }
    var ci = cells; // the cursors -> ends; offsets again
    while (ci > 0) : (ci -= 1) g.off[ci] = g.off[ci - 1];
    g.off[0] = 0;
    ngrids += 1;
    return g;
}

/// cvttps2dq: out of range or NaN gives the minimum.
fn cvttps(x: f32) i32 {
    return nt.cvtt(x);
}

/// tri_cells: the cells triangle t's box touches (x0 y0 z0 x1 y1 z1).
fn triCells(g: *const Grid, t: u32) [6]i32 {
    const me = g.me;
    var lo: V = .{ 1.0e30, 1.0e30, 1.0e30, 0 };
    var hi: V = .{ -1.0e30, -1.0e30, -1.0e30, 0 };
    for (0..3) |c| {
        const v = me.verts[me.tris[t][c]];
        const p: V = .{ v[0], v[1], v[2], 0 };
        lo = minps(lo, p);
        hi = maxps(hi, p);
    }
    const b: V = .{ me.lo[0], me.lo[1], me.lo[2], 0 };
    const cs = sp(g.cell);
    const l = (lo - b) / cs;
    const h = (hi - b) / cs;
    var out: [6]i32 = undefined;
    inline for (0..3) |c| {
        var x = cvttps(l[c]);
        var y = cvttps(h[c]);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        const m = g.n[c] - 1;
        if (x > m) x = m;
        if (y > m) y = m;
        out[c] = x;
        out[c + 3] = y;
    }
    return out;
}

/// cell_of_pt: the cell of a point in the grid's space (clamped).
fn cellOf(g: *const Grid, p: V) [3]i32 {
    const b: V = .{ g.me.lo[0], g.me.lo[1], g.me.lo[2], 0 };
    var q = (p - b) / sp(g.cell);
    q = maxps(q, sp(-1));
    q = minps(q, sp(200));
    var out: [3]i32 = undefined;
    inline for (0..3) |c| {
        var x = cvttps(q[c]);
        if (x < 0) x = 0;
        const m = g.n[c] - 1;
        if (x > m) x = m;
        out[c] = x;
    }
    return out;
}

/// pl_free_grids: every grid given back.
fn freeGrids() void {
    for (grids[0..ngrids]) |*g| {
        A.free(g.off);
        A.free(g.ent);
        A.free(g.stamp);
    }
    ngrids = 0;
}

// --- scripts, the HUD ----------------------------------------------------------------------------

/// pl_script_step: play on for that time with those keys held (tests), in frames
/// of 1/60 s as the window plays it.
pub fn scriptStep(seconds: f32, fwd: f32, right: f32, upk: f32, run: bool) void {
    if (on != 1) return;
    var k: u32 = 0;
    // (comiss: NaN is "unordered", which jae reads as below: back, left, down)
    if (fwd > 0) k |= IN_FWD;
    if (!(fwd >= 0)) k |= IN_BACK;
    if (right > 0) k |= IN_RIGHT;
    if (!(right >= 0)) k |= IN_LEFT;
    if (upk > 0) k |= IN_UP;
    if (!(upk >= 0)) k |= IN_DOWN;
    if (run) k |= IN_RUN;
    keys = k;
    var t = seconds;
    while (t > 0) {
        const s = minss(t, 0.016666668);
        t = t - s;
        advance(s);
    }
    keys = 0;
}

/// pl_script_look: where the player looks (degrees).
pub fn scriptLook(y: f32, p: f32) void {
    yaw = y / 57.29578;
    pitch = minss(maxss(p / 57.29578, -1.5), 1.5);
    // (the original's yaw and pitch are the viewport camera's: cam_yaw, cam_pitch)
    if (view()) |v| setViewAngles(v);
    if (on == 1) camera();
}

/// cam_yaw / cam_pitch (radians): the viewport camera's, as pl_stat reads them.
/// The viewport keeps degrees where the original's cam_yaw / cam_pitch are
/// radians; while it still holds what play wrote, the radians are play's own
/// (degrees and back can be one bit off: -57.26 came back -57.2599983).
fn camYawPitch() [2]f32 {
    const v = view() orelse return .{ yaw, pitch };
    if (on != 0 and v.yaw == view_set[0] and v.pitch == view_set[1]) return .{ yaw, pitch };
    const d = @import("math.zig").deg;
    return .{ v.yaw * d, v.pitch * d };
}

/// (the viewport's angles as play last set them, in degrees)
var view_set: [2]f32 = .{ std.math.nan(f32), std.math.nan(f32) };

fn setViewAngles(v: anytype) void {
    const d = @import("math.zig").deg;
    v.yaw = yaw / d;
    v.pitch = pitch / d;
    view_set = .{ v.yaw, v.pitch };
}

/// pl_stat: 0 state, 1-3 the feet, 4 on the ground, 5-7 velocity, 8 mode, 9 yaw,
/// 10 pitch (degrees), 11 seconds played, 12 the frame, 13 the mouse captured,
/// 14 steps taken, 15 meshes with a grid, 16-18 its up.
pub fn stat(k: u32) f32 {
    return switch (k) {
        0 => @floatFromInt(on),
        1...3 => @as([4]f32, pos)[k - 1],
        4 => @floatFromInt(@intFromBool(ground)),
        5...7 => @as([4]f32, vel)[k - 5],
        8 => @floatFromInt(mode),
        9 => camYawPitch()[0] * 57.29578,
        10 => camYawPitch()[1] * 57.29578,
        11 => time,
        12 => @import("anim.zig").frame,
        13 => @floatFromInt(@intFromBool(locked)),
        14 => @floatFromInt(steps),
        15 => @floatFromInt(ngrids),
        16...18 => @as([4]f32, up)[k - 16],
        else => 0,
    };
}

pub const hud_walk = "PLAY   WASD move   mouse look   Space jump   Shift run   F fly   Esc stop";
pub const hud_fly = "PLAY (fly)   WASD move   mouse look   Space up   C down   Shift faster   F walk   Esc stop";
pub const hud_ask = "Play stopped:   K  keep the changes      D  discard them";

/// play_hud (the viewport): what the keys do, or the question.
pub fn hud(cv: anytype, x0: i32, x1: i32, y1: i32, th: anytype) void {
    if (on == 0) return;
    cv.fill(.{ .x = x0 + 10, .y = y1 - 30, .w = x1 - x0 - 20, .h = 22 }, 0x1d2027);
    const s = if (on == 2) hud_ask else if (mode == 2) hud_fly else hud_walk;
    _ = cv.text(x0 + 18, y1 - 27, s, if (on == 2) th.accent else th.text);
}

/// What the viewport's drawing depends on (stateKey).
pub fn stateWord() u64 {
    return @as(u64, on) | @as(u64, mode) << 8;
}

const Impl = ops.Impl;
pub const list = .{
    .{ "play.start", Impl{ .run = opStart } },
    .{ "play.stop", Impl{ .run = opStop } },
    .{ "play.mode", Impl{ .run = opMode } },
};

// --- the test driver: --play "step S F R U RUN" | "look Y P" | "key CODE DOWN" | "dump OUT TAG [what...]" ---

/// The original's BeeScript playstep / playlook / playkey and a line of numbers
/// (as bits) for the tests: playinfo 0..18 (p), logic 0..8 (l), logicvar
/// object k c (v:Name:k:c), an object's loc, radians, scale and hidden (o:Name).
pub fn driver(spec: []const u8) void {
    var w = nt.Words{ .s = spec };
    const cmd = w.next();
    if (std.mem.eql(u8, cmd, "step")) {
        var a: [5]f32 = .{ 0, 0, 0, 0, 0 };
        for (&a) |*x| x.* = w.num() orelse break;
        scriptStep(a[0], a[1], a[2], a[3], nt.cvtt(a[4]) != 0);
    } else if (std.mem.eql(u8, cmd, "look")) {
        const y = w.num() orelse 0;
        const p = w.num() orelse 0;
        scriptLook(y, p);
    } else if (std.mem.eql(u8, cmd, "key")) {
        const c = w.num() orelse 0;
        const d = w.num() orelse 0;
        _ = key(@intCast(@max(nt.cvtt(c), 0)), nt.cvtt(d) != 0);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        var pbuf: [512]u8 = undefined;
        const p0 = w.next();
        const path = pbuf[0..@min(p0.len, pbuf.len)];
        @memcpy(path, p0[0..path.len]);
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        const tag = w.next();
        len += (std.fmt.bufPrint(buf[len..], "{s}", .{tag}) catch return).len;
        while (true) {
            const it = w.next();
            if (it.len == 0) break;
            var vals: [24]f32 = undefined;
            var nv: usize = 0;
            if (std.mem.eql(u8, it, "p")) {
                for (0..19) |k| vals[k] = stat(@intCast(k));
                nv = 19;
            } else if (std.mem.eql(u8, it, "l")) {
                for (0..9) |k| vals[k] = logic.stat(@intCast(k));
                nv = 9;
            } else if (std.mem.startsWith(u8, it, "v:")) {
                var p = std.mem.splitScalar(u8, it[2..], ':');
                const nm = p.next() orelse "";
                const k = std.fmt.parseInt(u32, p.next() orelse "0", 10) catch 0;
                const c = std.fmt.parseInt(u32, p.next() orelse "0", 10) catch 0;
                const oi = scene.find(nm);
                const v = if (oi) |i| logic.variable(scene.objects[i].oid, k, c) else null;
                if (v) |x| {
                    vals[0] = x;
                    nv = 1;
                } else {
                    len += (std.fmt.bufPrint(buf[len..], " nil", .{}) catch return).len;
                }
            } else if (std.mem.startsWith(u8, it, "o:")) {
                if (scene.find(it[2..])) |i| {
                    const o = &scene.objects[i];
                    const r = o.radians();
                    vals[0..10].* = .{ o.loc[0], o.loc[1], o.loc[2], r[0], r[1], r[2], o.scl[0], o.scl[1], o.scl[2], if (o.visible) 0 else 1 };
                    nv = 10;
                } else {
                    len += (std.fmt.bufPrint(buf[len..], " nil", .{}) catch return).len;
                }
            } else if (std.mem.eql(u8, it, "n")) {
                vals[0] = @floatFromInt(scene.count);
                nv = 1;
            }
            for (vals[0..nv]) |x| len += (std.fmt.bufPrint(buf[len..], " {x:0>8}", .{@as(u32, @bitCast(x))}) catch return).len;
        }
        len += (std.fmt.bufPrint(buf[len..], "\n", .{}) catch return).len;
        appendFile(path, buf[0..len]);
    }
}

fn appendFile(path: []const u8, data: []const u8) void {
    const linux = std.os.linux;
    var pz: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pz, "{s}", .{path}, 0) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, data.ptr, data.len);
}
