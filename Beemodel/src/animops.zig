// The anim.* operators (anim.s, animui.s, rig.s drivers): keys, frames, playback,
// key edits, actions, layers, drivers. Scripts, the console, menus and the
// editors all run these.
const std = @import("std");
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const frange = @import("frange.zig");
const axpr = @import("animexpr.zig");
const undo = @import("undo.zig");
const A = @import("alloc.zig").A;
const K = anim;

const Words = std.mem.TokenIterator(u8, .any);
fn words() Words {
    return std.mem.tokenizeAny(u8, ops.arg, " \"");
}

/// a decimal number (parse_float), finite
fn num(s: []const u8) ?f32 {
    for (s) |c| {
        if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) return null;
    }
    const v = std.fmt.parseFloat(f32, s) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

/// an_num: the next word as a number (the word goes either way).
fn next(it: *Words) ?f32 {
    return num(it.next() orelse return null);
}

fn word(w: []const u8, s: []const u8) bool {
    return std.mem.eql(u8, w, s);
}

const interp_names = [_][]const u8{ "constant", "linear", "bezier" };
fn interpIndex(w: []const u8) ?u8 {
    for (interp_names, 0..) |n, i| {
        if (word(n, w)) return @intCast(i);
    }
    return null;
}

fn roundI(f: f32) i64 {
    return if (@abs(f) < 1e15) @intFromFloat(@round(f)) else 0;
}

pub fn pollObject() ?[]const u8 {
    return null;
}

/// I: the selected objects' location, rotation and scale at this frame.
pub fn insertKey() void {
    var n: usize = 0;
    for (0..scene.count) |i| {
        if (!scene.objects[i].selected) continue;
        anim.keyObject(i, anim.frame);
        n += 1;
    }
    if (n == 0) return app.log("  nothing selected to key", .{});
    app.log("  keyed at frame {d}", .{roundI(anim.frame)});
}

pub fn deleteKey() void {
    // (a step, whatever it finds: do_an_del has no way back from run_op's)
    if (anim.cur != null) _ = anim.own(0);
    for (0..scene.count) |i| {
        if (scene.objects[i].selected) anim.unkeyObject(i, anim.frame);
    }
}

const s_bad = "  no such property to key (paths: Cube:x, material:M:roughness, modifier:Cube:0:levels, node:Tree:3:5, bone:Rig:Bone:rz, shape:Cube:Smile, param:angle): {s}";

/// anim.key <path> [frame] [value] [constant|linear|bezier]
pub fn keyPath() void {
    var it = words();
    const p = it.next() orelse return app.log(s_bad, .{""});
    var f = anim.frame;
    if (next(&it)) |x| f = x;
    const v: ?f32 = next(&it);
    var int: u8 = 2;
    if (it.next()) |w| {
        if (interpIndex(w)) |k| int = k;
    }
    if (anim.pathKey(p, f, v, int) == null) app.log(s_bad, .{p});
}

/// anim.unkey <path> [frame]
pub fn unkeyPath() void {
    var it = words();
    const p = it.next() orelse return;
    var f = anim.frame;
    if (next(&it)) |x| f = x;
    const ch = anim.parsePath(p) orelse return;
    _ = anim.unkey(ch, 0, f);
}

pub fn goFrame() void {
    var it = words();
    if (next(&it)) |f| anim.apply(f);
}

pub fn play() void {
    anim.play();
}
pub fn isPlaying() bool {
    return anim.playing;
}
pub fn nextFrame() void {
    anim.apply(1 + anim.frame);
}
pub fn prevFrame() void {
    anim.apply(-1 + anim.frame);
}
pub fn firstFrame() void {
    anim.apply(@floatFromInt(frange.r.start));
}
pub fn lastFrame() void {
    anim.apply(@floatFromInt(frange.r.end));
}

/// anim.interpolation <constant|linear|bezier>: every key of the selected
/// objects' curves (transforms and modifiers)
pub fn interpolation() void {
    var it = words();
    const k = interpIndex(it.next() orelse return) orelse return;
    setInterp(k);
}

fn selectedCurve(c: *const K.Curve) bool {
    if (c.kind != K.K_OBJ and c.kind != K.K_MOD) return false;
    const i = scene.findOid(c.a) orelse return false;
    return scene.objects[i].selected;
}

fn setInterp(k: u8) void {
    const b0 = anim.cur orelse return;
    var any = false;
    for (b0.curves()) |*c| {
        if (!selectedCurve(c)) continue;
        for (b0.keysOf(c)) |*x| {
            if (x.int != k) any = true;
        }
    }
    if (!any) return;
    const b = anim.own(0) orelse return;
    for (b.curves()) |*c| {
        if (!selectedCurve(c)) continue;
        for (b.keysOf(c)) |*x| x.int = k;
    }
    app.dirty = true;
}

// --- editing keys ----------------------------------------------------------------------

pub fn selCount() usize {
    const b = anim.cur orelse return 0;
    var n: usize = 0;
    for (b.curves()) |*c| {
        if (c.act != 0) continue;
        for (b.keysOf(c)) |*k| {
            if (k.sel != 0) n += 1;
        }
    }
    return n;
}

/// Every key of the scene's curves (selection: no undo step, the block as it is).
pub fn selAll(on: bool) void {
    app.dirty = true;
    const b = anim.cur orelse return;
    for (b.keys[0..b.h.nkey]) |*k| k.sel = @intFromBool(on);
}

/// anim.select_keys all | none | frame <f> | <path> <frame> [extend]
pub fn selectKeys() void {
    var it = words();
    const w = it.next() orelse return;
    app.dirty = true;
    if (word(w, "all")) return selAll(true);
    if (word(w, "none")) return selAll(false);
    if (word(w, "frame")) {
        const f = next(&it) orelse return;
        selAll(false);
        const b = anim.cur orelse return;
        for (b.keys[0..b.h.nkey]) |*k| {
            if (@abs(k.f - f) < 1.0e-4) k.sel = 1;
        }
        return;
    }
    const f = next(&it) orelse return;
    const ext = if (it.next()) |x| word(x, "extend") else false;
    if (!ext) selAll(false);
    if (keyAt(w, f)) |k| k.sel = 1;
}

fn keyAt(path: []const u8, f: f32) ?*K.Key {
    const ch = anim.parsePath(path) orelse return null;
    const ci = anim.find(ch, 0) orelse return null;
    const b = anim.cur.?;
    for (b.keysOf(&b.h.cur[ci])) |*k| {
        if (@abs(k.f - f) < 1.0e-4) return k;
    }
    return null;
}

const Taken = struct { ch: K.Chan, act: u32, k: K.Key };
var taken: std.ArrayListUnmanaged(Taken) = .empty;

/// The selected keys out of their curves, kept in `taken`.
fn collect() usize {
    taken.clearRetainingCapacity();
    if (selCount() == 0) return 0;
    const b = anim.own(0) orelse return 0;
    for (b.curves()) |*c| {
        if (c.act != 0) continue;
        for (b.keysOf(c)) |*k| {
            if (k.sel != 0) taken.append(A, .{ .ch = .{ .kind = c.kind, .a = c.a, .b = c.b, .c = c.c }, .act = c.act, .k = k.* }) catch return 0;
        }
    }
    delSelected(b);
    return taken.items.len;
}

fn delSelected(b: *K.Block) void {
    var ci = b.h.ncur;
    while (ci > 0) {
        ci -= 1;
        const c = &b.h.cur[ci];
        if (c.act != 0) continue;
        var w: u32 = c.n;
        while (w > 0) {
            w -= 1;
            const at = c.first + w;
            if (b.keys[at].sel == 0) continue;
            std.mem.copyForwards(K.Key, b.keys[at .. b.h.nkey - 1], b.keys[at + 1 .. b.h.nkey]);
            b.h.nkey -= 1;
            c.n -= 1;
            for (b.h.cur[ci + 1..b.h.ncur]) |*l| l.first -= 1;
        }
        if (c.n == 0) {
            std.mem.copyForwards(K.Curve, b.h.cur[ci .. b.h.ncur - 1], b.h.cur[ci + 1 .. b.h.ncur]);
            b.h.ncur -= 1;
        } else anim.handles(b, ci);
    }
}

/// The collected keys back, moved (and selected).
fn reinsert(df: f32, dv: f32, scale: f32, pivot: f32) void {
    for (taken.items) |*t| {
        const k = &t.k;
        // (past what a float holds: it stays, it must not end up nowhere)
        var f = (k.f - pivot) * scale + pivot + df;
        if (!std.math.isFinite(f)) f = k.f;
        var v = k.v + dv;
        if (!std.math.isFinite(v)) v = k.v;
        _ = anim.key(t.ch, t.act, f, v, k.int, .{ .sel = true, .ht = k.ht, .h = .{ k.hlx, k.hly, k.hrx, k.hry } });
    }
}

const s_nosel = "  no keys selected";

/// anim.move_keys <frames> [value]
pub fn moveKeys() void {
    var it = words();
    const df = next(&it) orelse return app.log(s_nosel, .{});
    const dv = next(&it) orelse 0;
    if (collect() == 0) return app.log(s_nosel, .{});
    reinsert(df, dv, 1, 0);
}

/// anim.scale_keys <factor>: around the current frame
pub fn scaleKeys() void {
    var it = words();
    const s = next(&it) orelse return app.log(s_nosel, .{});
    if (collect() == 0) return app.log(s_nosel, .{});
    reinsert(0, 0, s, anim.frame);
}

pub fn deleteKeys() void {
    if (selCount() == 0) return app.log(s_nosel, .{});
    const b = anim.own(0) orelse return;
    delSelected(b);
}

/// anim.duplicate_keys <frames>: copies (selected), the originals stay
pub fn duplicateKeys() void {
    var it = words();
    const df = next(&it) orelse return app.log(s_nosel, .{});
    if (collect() == 0) return app.log(s_nosel, .{});
    reinsert(0, 0, 1, 0);
    selAll(false);
    reinsert(df, 0, 1, 0);
}

/// anim.handle_type <auto|free>
pub fn handleType() void {
    var it = words();
    const free = if (it.next()) |w| word(w, "free") else false;
    setHandleType(free);
}

fn setHandleType(free: bool) void {
    const b = anim.own(0) orelse return;
    for (b.curves()) |*c| {
        if (c.act != 0) continue;
        for (b.keysOf(c)) |*k| {
            if (k.sel != 0) k.ht = @intFromBool(free);
        }
    }
    anim.allHandles(b);
}

/// anim.handle <path> <frame> <left|right> <frames> <value>
pub fn handle() void {
    var it = words();
    const p = it.next() orelse return;
    const f = next(&it) orelse return;
    const right = word(it.next() orelse return, "right");
    const hx = next(&it) orelse return;
    const hy = next(&it) orelse return;
    if (keyAt(p, f) == null) return;
    _ = anim.own(0) orelse return;
    const k = keyAt(p, f) orelse return;
    k.ht = 1;
    if (right) {
        k.hrx = hx;
        k.hry = hy;
    } else {
        k.hlx = hx;
        k.hly = hy;
    }
    app.dirty = true;
}

// --- actions, layers -------------------------------------------------------------------

fn objCurve(c: *const K.Curve) bool {
    return c.act == 0 and selectedCurve(c);
}

/// anim.action <name>: the selected objects' keys copied into a new action
pub fn action() void {
    var it = words();
    const nm = it.next() orelse return;
    const b0 = anim.cur orelse return app.log("  the selected objects have no keys to make an action of", .{});
    var total: u32 = 0;
    for (b0.curves()) |*c| {
        if (objCurve(c)) total += c.n;
    }
    if (total == 0) return app.log("  the selected objects have no keys to make an action of", .{});
    if (b0.h.nact >= K.MAXA) return app.log("  no room for more actions / layers", .{});
    const b = anim.own(total) orelse return;
    const ac = &b.h.act[b.h.nact];
    ac.* = .{ .name = @splat(0), .start = 1.0e30, .end = -1.0e30 };
    const n = @min(nm.len, 31);
    @memcpy(ac.name[0..n], nm[0..n]);
    b.h.nact += 1;
    const act = b.h.nact;
    const ncur = b.h.ncur;
    for (0..ncur) |ci| {
        const c = &b.h.cur[ci];
        if (!objCurve(c)) continue;
        if (b.h.ncur >= K.MAXC) return app.log("  no room for more actions / layers", .{});
        const at = b.h.ncur;
        b.h.cur[at] = c.*;
        b.h.cur[at].first = b.h.nkey;
        b.h.cur[at].act = act;
        b.h.ncur += 1;
        for (0..c.n) |q| {
            const k = b.keys[c.first + q];
            if (k.f < ac.start) ac.start = k.f;
            if (k.f > ac.end) ac.end = k.f;
            b.keys[b.h.nkey] = k;
            b.h.nkey += 1;
        }
    }
    app.dirty = true;
}

fn actionFind(nm: []const u8) ?u32 {
    const b = anim.cur orelse return null;
    for (b.actions(), 0..) |*a, i| {
        if (word(std.mem.sliceTo(&a.name, 0), nm)) return @intCast(i + 1);
    }
    return null;
}

/// anim.layer <action> [object|-] [start] [influence] [replace|add] [repeat]
pub fn layer() void {
    var it = words();
    const nm = it.next() orelse return;
    const act = actionFind(nm) orelse return app.log("  no action named {s}", .{nm});
    var l = K.Layer{ .act = act, .target = 0, .start = @floatFromInt(frange.r.start), .infl = 1, .mode = 0, .repeat = 1, .mute = 0 };
    parse: {
        const o = it.next() orelse break :parse;
        if (!word(o, "-")) {
            const i = blk: {
                for (scene.objects[0..scene.count], 0..) |*x, q| {
                    if (word(x.name(), o)) break :blk q;
                }
                return;
            };
            l.target = scene.objects[i].oid;
        }
        l.start = next(&it) orelse break :parse;
        l.infl = next(&it) orelse break :parse;
        const md = it.next() orelse break :parse;
        l.mode = @intFromBool(word(md, "add"));
        l.repeat = next(&it) orelse break :parse;
    }
    if (anim.cur.?.h.nlay >= K.MAXL) return app.log("  no room for more actions / layers", .{});
    const b = anim.own(0) orelse return;
    b.h.lay[b.h.nlay] = l;
    b.h.nlay += 1;
    anim.apply(anim.frame);
}

const s_lay = "  anim.layer_set <layer 1..> <influence|start|repeat|mode|mute> <value>";

/// anim.layer_set <layer> <influence|start|repeat|mode|mute> <value>
pub fn layerSet() void {
    var it = words();
    const ln = next(&it) orelse return app.log(s_lay, .{});
    const w = it.next() orelse return app.log(s_lay, .{});
    const names = [_][]const u8{ "influence", "start", "repeat", "mode", "mute" };
    var what: usize = 0;
    while (what < names.len and !word(names[what], w)) what += 1;
    if (what == names.len) return app.log(s_lay, .{});
    const v = next(&it) orelse return app.log(s_lay, .{});
    const b0 = anim.cur orelse return app.log(s_lay, .{});
    if (!(ln >= 1 and ln < @as(f32, @floatFromInt(b0.h.nlay + 1)))) return app.log(s_lay, .{});
    const li: usize = @intFromFloat(ln - 1);
    const b = anim.own(0) orelse return;
    const l = &b.h.lay[li];
    switch (what) {
        0 => l.infl = v,
        1 => l.start = v,
        2 => l.repeat = v,
        3 => l.mode = if (@abs(v) < 2e9) @bitCast(@as(i32, @intFromFloat(v))) else 0,
        else => l.mute = if (@abs(v) < 2e9) @bitCast(@as(i32, @intFromFloat(v))) else 0,
    }
    anim.apply(anim.frame);
}

/// anim.layer_remove <layer>
pub fn layerRemove() void {
    var it = words();
    const ln = next(&it) orelse return;
    const b0 = anim.cur orelse return;
    if (!(ln >= 1 and ln < @as(f32, @floatFromInt(b0.h.nlay + 1)))) return;
    removeLayer(@intFromFloat(ln - 1));
}

pub fn removeLayer(li: usize) void {
    const b = anim.own(0) orelse return;
    if (li >= b.h.nlay) return;
    std.mem.copyForwards(K.Layer, b.h.lay[li .. b.h.nlay - 1], b.h.lay[li + 1 .. b.h.nlay]);
    b.h.nlay -= 1;
    app.dirty = true;
}

// --- drivers ---------------------------------------------------------------------------

fn nameOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 8) return false;
    for (s, 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return false;
    }
    return true;
}

fn evalCheck(d: *const K.Driver) bool {
    return anim.driverValue(d, 31) != null;
}

/// anim.driver <path> [name=path ...] <expression>
pub fn driver() void {
    const bad = "  anim.driver <path> [name=path ...] <expression> - not a property: {s}";
    var it = words();
    const p = it.next() orelse return app.log(bad, .{""});
    const ch = anim.parsePath(p) orelse return app.log(bad, .{p});
    var d = std.mem.zeroes(K.Driver);
    d.kind = ch.kind;
    d.a = ch.a;
    d.b = ch.b;
    d.c = ch.c;
    var ex: []const u8 = "";
    while (true) {
        const save = it.index;
        const w = it.next() orelse return app.log(bad, .{""});
        const eq = std.mem.indexOfScalar(u8, w, '=');
        if (eq == null or !nameOk(w[0..eq.?])) {
            it.index = save;
            ex = std.mem.trim(u8, it.rest(), " \"");
            break;
        }
        if (d.nv >= 4) return app.log(bad, .{w});
        const vc = anim.parsePath(w[eq.? + 1..]) orelse return app.log(bad, .{w});
        const v = &d.vars[d.nv];
        @memcpy(v.name[0..eq.?], w[0..eq.?]);
        v.kind = vc.kind;
        v.a = vc.a;
        v.b = vc.b;
        v.c = vc.c;
        d.nv += 1;
    }
    const n = @min(ex.len, d.expr.len - 1);
    @memcpy(d.expr[0..n], ex[0..n]);
    if (!evalCheck(&d)) return app.log("  the driver's expression: {s}", .{"not a number (domain or division)"});
    const b0: ?*K.Block = anim.cur;
    var at: usize = if (b0) |b| b.h.ndrv else 0;
    if (b0) |b| {
        for (b.drivers(), 0..) |*x, q| {
            if (x.kind == d.kind and x.a == d.a and x.b == d.b and x.c == d.c) at = q;
        }
    }
    if (at >= K.MAXDRV) return app.log("  no room for more constraints / drivers", .{});
    const b = anim.own(0) orelse return;
    b.h.drv[at] = d;
    if (at == b.h.ndrv) b.h.ndrv += 1;
    app.dirty = true;
}

/// anim.driver_remove <path>
pub fn driverRemove() void {
    var it = words();
    const p = it.next() orelse return;
    const ch = anim.parsePath(p) orelse return app.log("  no driver on {s}", .{p});
    const b0 = anim.cur orelse return app.log("  no driver on {s}", .{p});
    for (b0.drivers(), 0..) |*x, q| {
        if (x.kind == ch.kind and x.a == ch.a and x.b == ch.b and x.c == ch.c) return dropDriver(q);
    }
    app.log("  no driver on {s}", .{p});
}

fn dropDriver(q: usize) void {
    const b = anim.own(0) orelse return;
    std.mem.copyForwards(K.Driver, b.h.drv[q .. b.h.ndrv - 1], b.h.drv[q + 1 .. b.h.ndrv]);
    b.h.ndrv -= 1;
    app.dirty = true;
}

/// anim.driver_set <n> expression <text> | mute <0|1> | remove
pub fn driverSet() void {
    const bad = "  anim.driver_set <n> expression <text> | mute <0|1> | remove";
    var it = words();
    const ln = next(&it) orelse return app.log(bad, .{});
    const b0 = anim.cur orelse return app.log(bad, .{});
    if (!(ln >= 1 and ln < @as(f32, @floatFromInt(b0.h.ndrv + 1)))) return app.log(bad, .{});
    const q: usize = @intFromFloat(ln - 1);
    const w = it.next() orelse return app.log(bad, .{});
    if (word(w, "expression")) {
        const t = std.mem.trim(u8, it.rest(), " \"");
        if (t.len == 0) return app.log(bad, .{});
        const b = anim.own(0) orelse return;
        const d = &b.h.drv[q];
        d.expr = @splat(0);
        const n = @min(t.len, d.expr.len - 1);
        @memcpy(d.expr[0..n], t[0..n]);
    } else if (word(w, "mute")) {
        const v = next(&it) orelse return app.log(bad, .{});
        const b = anim.own(0) orelse return;
        b.h.drv[q].mute = if (@abs(v) < 2e9) @bitCast(@as(i32, @intFromFloat(v))) else 0;
    } else if (word(w, "remove")) {
        dropDriver(q);
    } else return app.log(bad, .{});
    app.dirty = true;
}

// --- auto-key, the key menu, the range at this frame --------------------------------------

pub fn autoKeyToggle() void {
    anim.autokey = !anim.autokey;
    app.dirty = true;
}
pub fn autoKeyOn() bool {
    return anim.autokey;
}

var autokey_due = false;

/// A transform was confirmed: the selected objects get keys, a step of its own.
pub fn autokeyConfirm() void {
    if (anim.autokey) autokey_due = true;
}

/// After that transform's step.
pub fn autokeyStep() bool {
    if (!autokey_due) return false;
    autokey_due = false;
    ops.runId("anim.insert_key");
    return true;
}

pub fn keysConstant() void {
    setInterp(0);
}
pub fn keysLinear() void {
    setInterp(1);
}
pub fn keysBezier() void {
    setInterp(2);
}
pub fn keysAuto() void {
    setHandleType(false);
}
pub fn keysFree() void {
    setHandleType(true);
}

/// anim.range, the speed as it is (past a whole number's range it is left out:
/// the original's cvttss2si gives a negative one there, which anim.range ignores).
pub fn rangeFps(s: i64, e: i64, fps: f32) void {
    var b: [64]u8 = undefined;
    if (fps < 1e9) {
        runText("anim.range", std.fmt.bufPrint(&b, "{d} {d} {d}", .{ s, e, @as(i64, @intFromFloat(fps)) }) catch return);
    } else runText("anim.range", std.fmt.bufPrint(&b, "{d} {d}", .{ s, e }) catch return);
}

fn rangeRun(s: i64, e: i64) void {
    rangeFps(s, e, frange.r.fps);
}

pub fn startHere() void {
    rangeRun(roundI(anim.frame), frange.r.end);
}
pub fn endHere() void {
    rangeRun(frange.r.start, roundI(anim.frame));
}

/// Run an operator with an argument (the editors: one undo step, as scripts).
pub fn runText(id: []const u8, text: []const u8) void {
    const i = ops.byId(id) orelse return;
    const sa = ops.arg;
    const ss = ops.scripted;
    defer {
        ops.arg = sa;
        ops.scripted = ss;
    }
    ops.arg = text;
    ops.scripted = true;
    ops.run(i);
}

pub fn delKeysKey() void {
    if (selCount() > 0) runText("anim.delete_keys", "");
}
pub fn selAllKey() void {
    selAll(selCount() == 0);
}
pub fn dupKeysKey() void {
    runText("anim.duplicate_keys", "10");
}
