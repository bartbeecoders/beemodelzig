// Logic graphs (logic.s): event nodes that run in play mode.
//
// A logic graph is a node tree (ntree.zig) marked as logic (TR_KIND), so it is
// saved, undone and edited like the geometry trees; an object runs one through
// a Logic modifier (mods.zig: the modifier names the tree; it changes no
// geometry). The record's spare tail holds 30 names (16 bytes each) that nodes
// refer to by number: messages, objects, properties, actions.
//
// Nodes: events start chains (begin play, tick, key, overlap, hit, timer,
// message); actions run when the node feeding their Run input fires (move,
// rotate, set property, spawn, destroy, play action, impulse, shatter,
// visibility, send message, set variable, set strength; branch picks one of
// two ways on); data nodes (variable, math, info, get property, field) are
// pulled for the inputs that need them. Links point from an input to the
// output that feeds it, so a chain is found by looking for the nodes whose Run
// input takes the output that fired; links never loop, so every chain ends.
//
// The VM: play mode's fixed steps (1/120 s) run every object's graph, in the
// order the objects were found, events in node order, then the messages sent
// meanwhile (each to every graph listening, or to one object). Deterministic:
// no clocks, no threads; "random" is a hash of the step, the node and the
// object. Sandboxed: a graph only touches objects of the scene by name, a step
// runs at most 4096 nodes (past it the rest of that step's nodes are skipped),
// 256 messages a step and 256 spawned objects; no files, no operators.
// Everything it changes is undone with play mode (play.zig).
//
// Every float is computed as the original's SSE code does, lane by lane, in
// its order (minps / maxps / comiss and their NaNs too), so the scene it moves
// is the original's bit for bit.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const nt = @import("ntree.zig");
const ops = @import("ops.zig");
const ax = @import("animexpr.zig");

pub const TR_STR = nt.GR_NODES + nt.NT_MAXN * nt.NODE_SZ; // names: 30 x 16 bytes
pub const STR_N = 30;
pub const STR_SZ = 16;

// node types
pub const LT_BEGIN = 1;
pub const LT_TICK = 2;
pub const LT_KEY = 3;
pub const LT_OVER = 4;
pub const LT_HIT = 5;
pub const LT_TIMER = 6;
pub const LT_MSG = 7;
pub const LT_MOVE = 8;
pub const LT_ROT = 9;
pub const LT_SETP = 10;
pub const LT_SPAWN = 11;
pub const LT_DESTROY = 12;
pub const LT_ACTION = 13;
pub const LT_IMPULSE = 14;
pub const LT_VIS = 15;
pub const LT_SEND = 16;
pub const LT_SETVAR = 17;
pub const LT_BRANCH = 18;
pub const LT_VAR = 19;
pub const LT_MATH = 20;
pub const LT_INFO = 21;
pub const LT_GETP = 22;
pub const LT_SHATTER = 23;
pub const LT_SETSTR = 24;
pub const LT_FIELD = 25;
pub const NTYPES = 25;

pub const type_names = [NTYPES][]const u8{ "begin", "tick", "key", "overlap", "hit", "timer", "message", "move", "rotate", "set_property", "spawn", "destroy", "play_action", "impulse", "visibility", "send", "set_variable", "branch", "variable", "math", "info", "get_property", "shatter", "set_strength", "field" };
pub const titles = [NTYPES + 1][]const u8{ "", "Begin Play", "On Tick", "On Key", "On Overlap", "On Hit", "On Timer", "On Message", "Move", "Rotate", "Set Property", "Spawn", "Destroy", "Play Action", "Apply Impulse", "Set Visibility", "Send Message", "Set Variable", "Branch", "Variable", "Math", "Info", "Get Property", "Shatter", "Set Strength", "Field" };
/// The kinds of each type's four values (lg_meta: 0 number, 1 choice, 3 whole, 5 name).
pub const value_kinds = [NTYPES + 1][4]u8{
    .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 3, 1, 0, 0 }, .{ 5, 1, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 5, 0, 0, 0 },
    .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 5, 5, 0, 0 }, .{ 5, 0, 0, 0 }, .{ 5, 0, 0, 0 }, .{ 5, 0, 0, 0 }, .{ 5, 0, 0, 0 }, .{ 5, 0, 0, 0 },
    .{ 5, 5, 0, 0 }, .{ 3, 1, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 3, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 5, 5, 0, 0 }, .{ 5, 0, 0, 0 },
    .{ 5, 0, 0, 0 }, .{ 0, 0, 0, 0 },
};

/// Defaults per type (lg_defaults): 4 values, then the 3 inputs' x y z. The
/// original's table has 23 rows: Set Strength and Field take theirs from the
/// bytes after it (the property table: "x" and its offset ...), as here.
const defaults = blk: {
    var d: [NTYPES][13]u32 = @splat(@splat(0));
    d[LT_KEY - 1][0] = @bitCast(@as(f32, 18)); // E, pressed
    d[LT_TIMER - 1][0] = @bitCast(@as(f32, 1));
    d[LT_ACTION - 1][1] = @bitCast(@as(f32, 1));
    for (7..10) |k| d[LT_VIS - 1][k] = @bitCast(@as(f32, 1));
    for (7..10) |k| d[LT_SEND - 1][k] = @bitCast(@as(f32, 1));
    d[LT_SETSTR - 1] = after_table[0..13].*;
    d[LT_FIELD - 1] = after_table[13..26].*;
    break :blk d;
};
/// What follows lg_defaults in the original's .rodata: lg_props, 16-byte rows
/// of a name ("x", "y" ... packed) and an object offset (OB_LOC 0x20 ...): what
/// logic.node gives a Set Strength or a Field node (read from its files).
const after_table = [26]u32{
    0x78, 0, 0x20, 0, 0x79, 0, 0x24, 0, 0x7a, 0, 0x28, 0, 0x7872,
    0,    0x2c, 0, 0x7972, 0, 0x30, 0, 0x7a72, 0, 0x34, 0, 0x7873, 0,
};

// --- the running graphs --------------------------------------------------------------------

const MAXI = 512;
const BUDGET = 4096;
const MAXQ = 256;
const MAXSPAWN = 256;

/// An instance: an object running a graph.
const Inst = struct {
    obj: u32 = 0, // its oid (the original's handle)
    tree: u32 = 0,
    flags: u32 = 0, // 1 begun, 2 gone, 4 touched last step
    inside: u64 = 0, // overlap nodes inside (bit per node, mod 64)
    tdone: u64 = 0, // one-shot timers done
    start: V = @splat(0), // where it was when play began
    vars: [8]V = @splat(@splat(0)),
    timer: [nt.NT_MAXN]f32 = @splat(0),
};
const Msg = struct { name: [16]u8, to: u32, value: f32 };

pub const V = @Vector(4, f32);

var tab: [MAXI]Inst = undefined;
var mq: [MAXQ]Msg = undefined;
var ctx_v1: f32 = 0; // the firing event's outputs 1, 2
var ctx_v2: f32 = 0;
var ctx_node: u32 = 0;
pub var on: bool = false;
var n: u32 = 0; // instances
var cur: u32 = 0; // the instance running
var rec: *const nt.Rec = undefined; // its graph
var mqn: u32 = 0;
var budget: i32 = 0;
var depth: u32 = 0;
var time: f32 = 0;
var dt: f32 = 0;
var steps: u32 = 0;
var runs: u32 = 0; // stats: nodes run
var runs_step: u32 = 0;
var events: u32 = 0;
var msgs: u32 = 0;
var spawned: u32 = 0;
var overs: u32 = 0;
var said: bool = false;
var kdown: std.StaticBitSet(256) = .empty;
var kpress: std.StaticBitSet(256) = .empty;
var krel: std.StaticBitSet(256) = .empty;
var tnow: std.StaticBitSet(4096) = .empty; // objects the player touched (oid & 4095)

// --- SSE, lane by lane ----------------------------------------------------------------------

const XYZ: @Vector(4, bool) = .{ true, true, true, false };
fn andXyz(v: V) V {
    return @select(f32, XYZ, v, @as(V, @splat(0)));
}
fn splat(x: f32) V {
    return @splat(x);
}
fn bits(v: V) @Vector(4, u32) {
    return @bitCast(v);
}
fn mask(c: @Vector(4, bool), v: V) V {
    return @select(f32, c, v, @as(V, @splat(0)));
}
/// minps a, b: a < b ? a : b (b when unordered)
fn minps(a: V, b: V) V {
    return @select(f32, a < b, a, b);
}
fn maxps(a: V, b: V) V {
    return @select(f32, a > b, a, b);
}
/// dpps 0x7f / 0x71: (x x' + y y') + (z z' + w w')
fn dot(a: V, b: V) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + p[3]);
}
/// cvttss2si: out of range or NaN gives the minimum.
const cvtt = nt.cvtt;

// --- graphs ----------------------------------------------------------------------------------

/// lg_is_logic
pub fn isLogic(t: u32) bool {
    const r = nt.get(t) orelse return false;
    return nt.rd32(r, nt.TR_KIND) == 1;
}

/// lg_name_of: name slot 1..30 of a record (null: none).
pub fn nameOf(r: *const nt.Rec, slot: i32) ?[]const u8 {
    if (slot < 1 or slot > STR_N) return null;
    const o = TR_STR + @as(usize, @intCast(slot - 1)) * STR_SZ;
    if (r[o] == 0) return null;
    return std.mem.sliceTo(r[o .. o + STR_SZ], 0);
}

/// lg_names_used: a bit per name slot some node's name value points at.
fn namesUsed(r: *const nt.Rec) u64 {
    var b: u64 = 0;
    var k: u32 = 1;
    while (k <= nt.nodes(r)) : (k += 1) {
        const o = nt.nodeAt(k);
        const t = nt.rd32(r, o + nt.ND_TYPE);
        if (t < 1 or t > NTYPES) continue;
        for (0..4) |d| {
            if (value_kinds[t][d] != 5) continue;
            const s = cvtt(nt.rdf(r, o + nt.ND_P + d * 4)) -% 1;
            if (@as(u32, @bitCast(s)) < STR_N) b |= @as(u64, 1) << @intCast(s);
        }
    }
    return b;
}

/// lg_arg_graph: the logic graph named by the next word (said when none).
fn argGraph(w: *nt.Words) ?u32 {
    const s = w.next();
    if (s.len > 0) {
        if (nt.find(s)) |t| {
            if (isLogic(t)) return t;
            app.log("  not a logic graph (logic.new makes one): {s}", .{s});
            return null;
        }
    }
    app.log("  no such node tree: {s}", .{s});
    return null;
}

// (a failed operator leaves the trees as they were: undo_drop_last)
var before: ?*nt.Block = null;
fn begin() void {
    before = null;
    nt.keep(&before);
}
fn fail() void {
    nt.restore(before);
    drop();
}
fn drop() void {
    var b = before;
    before = null;
    // (the reference the op held)
    if (b) |x| {
        x.refs -= 1;
        if (x.refs == 0) {
            if (x.r.len > 0) @import("alloc.zig").A.free(x.r);
            @import("alloc.zig").A.destroy(x);
        }
        b = null;
    }
}

/// logic.new [name]
fn opNew() void {
    var w = nt.Words{ .s = ops.arg };
    const s = w.next();
    const t = nt.new(if (s.len > 0) s else "Logic") orelse return;
    const r = nt.own(t).?;
    nt.wr32(r, nt.TR_KIND, 1);
    app.log("  logic graph: {s}", .{nt.name(r)});
}

/// logic.attach <graph> [object]
fn opAttach() void {
    var w = nt.Words{ .s = ops.arg };
    const t = argGraph(&w) orelse return;
    const need = "  logic.attach <graph> [object] (a mesh object)";
    const s = w.next();
    const oi: ?usize = if (s.len > 0) scene.find(s) else blk: {
        const a = scene.active;
        if (a == null or !scene.objects[a.?].kind.isMesh()) app.log("  modifiers need an active mesh object", .{});
        break :blk a;
    };
    const i = oi orelse return app.log("{s}", .{need});
    if (!scene.objects[i].kind.isMesh()) return app.log("{s}", .{need});
    const mods = @import("mods.zig");
    const k = mods.add(i, mods.LOGIC) orelse return app.log("{s}", .{need});
    mods.setF(&scene.objects[i].mods.m[k], 0, @floatFromInt(t + 1));
    app.log("  logic graph attached: {s}", .{scene.objects[i].name()});
}

/// lg_type_index
pub fn typeIndex(s: []const u8) ?u32 {
    for (type_names, 0..) |nm, k| {
        if (std.mem.eql(u8, nm, s)) return @intCast(k + 1);
    }
    return null;
}

const s_need = "  logic.node <graph> <type> [values]; types: begin tick key overlap hit timer message move rotate set_property spawn destroy play_action impulse visibility send set_variable branch variable math info get_property shatter";

/// logic.node <graph> <type> [values]
fn opNode() void {
    begin();
    var w = nt.Words{ .s = ops.arg };
    const t = argGraph(&w) orelse return fail();
    const ty = typeIndex(w.next()) orelse {
        app.log("{s}", .{s_need});
        return fail();
    };
    const d: [13]f32 = @bitCast(defaults[ty - 1]);
    const k = nt.add(t, ty, &d) orelse {
        app.log("{s}", .{s_need});
        return fail();
    };
    var slot: i32 = 4;
    while (slot < 8) : (slot += 1) {
        const v = w.num() orelse break;
        _ = nt.set(t, @intCast(k), slot, &.{v});
    }
    drop();
    app.log("  node {d}", .{k});
}

/// logic.name <graph> <node> <value 4-7> [text]
fn opName() void {
    begin();
    var w = nt.Words{ .s = ops.arg };
    const t = argGraph(&w) orelse return fail();
    const need = "  logic.name <graph> <node> <value 4-7> [text] (15 characters at most)";
    const node = cvtt(w.num() orelse return needed(need));
    const slot = cvtt(w.num() orelse return needed(need));
    if (slot < 4 or slot > 7) return needed(need);
    const text = w.next();
    if (text.len > STR_SZ - 1) return needed(need);
    var txt: [16]u8 = @splat(0);
    @memcpy(txt[0..text.len], text);
    const r = nt.own(t) orelse return fail();
    if (node <= 0 or node > @as(i64, nt.nodes(r))) return needed(need);
    var v: u32 = 0; // no text: none
    if (text.len > 0) {
        const used = namesUsed(r);
        var c: u32 = 0;
        const found: ?u32 = while (c < STR_N) : (c += 1) {
            if (used & (@as(u64, 1) << @intCast(c)) == 0) continue;
            const o = TR_STR + c * STR_SZ;
            if (std.mem.eql(u8, std.mem.sliceTo(r[o .. o + STR_SZ], 0), text)) break c;
        } else null;
        if (found) |f| v = f + 1 else {
            c = 0;
            while (c < STR_N and used & (@as(u64, 1) << @intCast(c)) != 0) c += 1;
            if (c >= STR_N) {
                app.log("  logic: the graph holds 30 names", .{});
                return fail();
            }
            @memcpy(r[TR_STR + c * STR_SZ ..][0..STR_SZ], &txt);
            v = c + 1;
        }
    }
    _ = nt.set(t, node, slot, &.{@floatFromInt(v)});
    drop();
}

fn needed(s: []const u8) void {
    app.log("{s}", .{s});
    fail();
}

// --- play mode ---------------------------------------------------------------------------------

const play = @import("play.zig");

/// lg_begin (play.start): every object with a Logic modifier gets its graph running.
pub fn beginPlay() void {
    n = 0;
    mqn = 0;
    time = 0;
    steps = 0;
    runs = 0;
    runs_step = 0;
    events = 0;
    msgs = 0;
    spawned = 0;
    overs = 0;
    said = false;
    kdown = .empty;
    kpress = .empty;
    krel = .empty;
    tnow = .empty;
    var i: usize = 0;
    while (i < scene.count) : (i += 1) addObj(scene.objects[i].oid);
    on = true;
}

/// lg_end (play.stop): nothing runs.
pub fn endPlay() void {
    on = false;
    n = 0;
}

/// lg_add_obj: an instance per enabled Logic modifier naming a logic graph.
fn addObj(oid: u32) void {
    const i = scene.findOid(oid) orelse return;
    const o = &scene.objects[i];
    if (!o.kind.isMesh()) return;
    const mods = @import("mods.zig");
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.kind != mods.LOGIC or d.flags & 1 == 0) continue;
        const t = cvtt(mods.getF(d, 0)) -% 1;
        if (t < 0) continue;
        if (!isLogic(@intCast(t))) continue;
        if (n >= MAXI) return;
        tab[n] = .{ .obj = oid, .tree = @intCast(t) };
        n += 1;
    }
}

/// lg_key (play_key): what the keys did.
pub fn key(code: u32, down: bool) void {
    if (code >= 256) return;
    if (down) {
        if (kdown.isSet(code)) return; // (repeats: held already)
        kdown.set(code);
        kpress.set(code);
    } else {
        if (!kdown.isSet(code)) return;
        kdown.unset(code);
        krel.set(code);
    }
}

/// lg_touch (play.zig): the player touched it this step.
pub fn touch(oid: u32) void {
    tnow.set(oid & 4095);
}

/// lg_stat: 0 running, 1 graphs running (objects), 2 nodes run, 3 events fired,
/// 4 messages sent, 5 objects spawned, 6 steps past the budget, 7 nodes the last
/// step ran, 8 steps.
pub fn stat(k: u32) f32 {
    const v: u32 = switch (k) {
        0 => @intFromBool(on),
        1 => n,
        2 => runs,
        3 => events,
        4 => msgs,
        5 => spawned,
        6 => overs,
        7 => runs_step,
        8 => steps,
        else => return 0,
    };
    return @floatFromInt(@as(i32, @bitCast(v)));
}

/// lg_var: variable k (0..7) of the object's first graph, component c.
pub fn variable(oid: u32, k: u32, c: u32) ?f32 {
    if (k >= 8 or c >= 3) return null;
    for (tab[0..n]) |*x| {
        if (x.obj == oid) {
            const a: [4]f32 = x.vars[k];
            return a[c];
        }
    }
    return null;
}

// --- the step --------------------------------------------------------------------------------

/// lg_step (play mode's fixed step): every graph: its events, then the messages sent.
pub fn step(seconds: f32) void {
    if (!on) return;
    dt = seconds;
    time = seconds + time;
    steps +%= 1;
    budget = BUDGET;
    const runs0 = runs;
    const n0 = n; // (spawned ones: from the next step)
    var ii: u32 = 0;
    while (ii < n0) : (ii += 1) {
        const in = enter(ii) orelse continue;
        const r = rec;
        if (in.flags & 1 == 0) {
            in.flags |= 1; // begun: where it starts, the timers
            const so = self().?;
            in.start = andXyz(locV(so));
            var k: u32 = 1;
            while (k <= nt.nodes(r)) : (k += 1) {
                const o = nt.nodeAt(k);
                if (nt.rd32(r, o + nt.ND_TYPE) == LT_TIMER) in.timer[k - 1] = nt.rdf(r, o + nt.ND_P);
            }
            fireAll(LT_BEGIN);
        }
        ctx_v1 = dt; // every tick
        ctx_v2 = time;
        fireAll(LT_TICK);
        var k: u32 = 1;
        while (in.flags & 2 == 0 and k <= nt.nodes(r)) : (k += 1) {
            const o = nt.nodeAt(k);
            const p0 = nt.rdf(r, o + nt.ND_P);
            const p1 = nt.rdf(r, o + nt.ND_P + 4);
            switch (nt.rd32(r, o + nt.ND_TYPE)) {
                LT_KEY => {
                    const c: u32 = @bitCast(cvtt(p0));
                    if (c >= 256) continue;
                    const when = cvtt(p1);
                    const set = if (when == 2) &kdown else if (when == 1) &krel else &kpress;
                    if (set.isSet(c)) fire(k);
                },
                LT_OVER => {
                    const now = overlap(k);
                    const bit = @as(u64, 1) << @intCast(k & 63);
                    const was = in.inside & bit != 0;
                    in.inside &= ~bit;
                    if (now) in.inside |= bit;
                    const when = cvtt(nt.rdf(rec, nt.nodeAt(k) + nt.ND_P + 4));
                    const go = switch (when) {
                        1 => !now and was, // leave
                        2 => now, // inside
                        else => now and !was, // enter
                    };
                    if (go) fire(k);
                },
                LT_HIT => {
                    if (!tnow.isSet(in.obj & 4095)) continue;
                    if (in.flags & 4 != 0) continue; // (touching last step too: no)
                    fire(k);
                },
                LT_TIMER => {
                    const bit = @as(u64, 1) << @intCast(k & 63);
                    if (in.tdone & bit != 0) continue;
                    var tm = in.timer[k - 1] - dt;
                    in.timer[k - 1] = tm;
                    if (tm > 0) continue;
                    if (cvtt(p1) != 0) { // repeat: again after the seconds
                        const per = if (p0 > dt) p0 else dt; // (maxss)
                        tm = tm + per;
                        in.timer[k - 1] = tm;
                    } else in.tdone |= bit;
                    fire(k);
                },
                else => {},
            }
        }
        // touched this step: remembered
        in.flags &= ~@as(u32, 4);
        if (tnow.isSet(in.obj & 4095)) in.flags |= 4;
    }
    deliver();
    kpress = .empty;
    krel = .empty;
    tnow = .empty;
    runs_step = runs -% runs0;
}

/// lg_enter: the instance (cur, rec set), or null (gone: its object or graph).
fn enter(i: u32) ?*Inst {
    const in = &tab[i];
    cur = i;
    if (in.flags & 2 != 0) return null;
    if (scene.findOid(in.obj) == null or nt.get(in.tree) == null or nt.rd32(nt.get(in.tree).?, nt.TR_KIND) != 1) {
        in.flags |= 2;
        return null;
    }
    rec = nt.get(in.tree).?;
    return in;
}

fn inst() *Inst {
    return &tab[cur];
}

/// lg_self: its object (index), or null.
fn self() ?usize {
    return scene.findOid(inst().obj);
}

fn nodeOff(k: u32) usize {
    return nt.nodeAt(k);
}
fn ptype(k: u32) u32 {
    return nt.rd32(rec, nodeOff(k) + nt.ND_TYPE);
}
fn pval(k: u32, v: usize) f32 {
    return nt.rdf(rec, nodeOff(k) + nt.ND_P + v * 4);
}

/// lg_vname: the name value v of node k holds, or null.
fn vname(k: u32, v: usize) ?[]const u8 {
    return nameOf(rec, cvtt(pval(k, v)));
}

/// lg_target: the object named there (none named: its own; a name not found: null).
fn target(k: u32, v: usize) ?usize {
    const nm = vname(k, v) orelse return self();
    return scene.find(nm);
}

fn fireAll(ty: u32) void {
    var b: u32 = 1;
    while (b <= nt.nodes(rec)) : (b += 1) {
        if (ptype(b) == ty) fire(b);
    }
}

/// lg_fire: its chain runs (ctx_v1 / v2: its outputs).
fn fire(k: u32) void {
    events +%= 1;
    ctx_node = k;
    runFrom(k, 0);
}

/// lg_run_from: the actions whose Run input takes that output.
fn runFrom(k: u32, out: u32) void {
    const want = (out << 16) | k;
    var b: u32 = 1;
    while (b <= nt.nodes(rec)) : (b += 1) {
        const t = ptype(b);
        if (!(t == LT_SHATTER or t == LT_SETSTR or (t >= LT_MOVE and t <= LT_BRANCH))) continue;
        if (nt.rd32(rec, nodeOff(b) + nt.ND_IN) & 0xffffff != want) continue;
        exec(b);
    }
}

fn locV(i: usize) V {
    const o = &scene.objects[i];
    return .{ o.loc[0], o.loc[1], o.loc[2], 0 };
}

/// lg_exec: an action (or branch) runs, then what follows it.
fn exec(k: u32) void {
    if (budget <= 0) {
        overs +%= 1; // past the budget: dropped
        if (!said) {
            said = true;
            app.log("  logic: a step reached 4096 nodes - the rest of it was skipped", .{});
        }
        return;
    }
    budget -= 1;
    runs +%= 1;
    var then: u32 = 0;
    switch (ptype(k)) {
        LT_SETSTR => blk: { // a force field's strength: Value's x
            const oi = target(k, 0) orelse break :blk;
            if (scene.objects[oi].kind != .field) break :blk;
            const uid = scene.objects[oi].uid;
            const v = input(k, 1)[0];
            const fr = @import("fields.zig").recOwn(uid, 0) orelse break :blk;
            fr.str = v;
            app.dirty = true;
        },
        LT_MOVE, LT_ROT => blk: {
            const rot = ptype(k) == LT_ROT;
            const kk: f32 = if (rot) 0.017453292 else 1.0;
            const v = input(k, 1) * splat(kk);
            const oi = self() orelse break :blk;
            const o = &scene.objects[oi];
            var now: V = v;
            if (cvtt(pval(k, 0)) == 0) { // by / to
                const was = if (rot) o.radians() else o.loc;
                now = v + V{ was[0], was[1], was[2], 0 };
            }
            if (rot) o.setRadians(.{ now[0], now[1], now[2] }) else o.loc = .{ now[0], now[1], now[2] };
            app.dirty = true;
        },
        LT_SETP => blk: {
            const v = input(k, 1)[0];
            const oi = target(k, 1) orelse break :blk;
            const nm = vname(k, 0) orelse break :blk;
            const p = prop(nm) orelse break :blk;
            setProp(oi, p, v);
        },
        LT_SPAWN => blk: {
            if (spawned >= MAXSPAWN) break :blk;
            const nm = vname(k, 0) orelse break :blk;
            const tmpl = scene.find(nm) orelse break :blk;
            const off = input(k, 1);
            const so = self() orelse break :blk;
            const at = andXyz(locV(so)) + off;
            const d = ops.objCopy(tmpl) orelse break :blk;
            const o = &scene.objects[d];
            o.loc = .{ at[0], at[1], at[2] };
            o.visible = true;
            o.selected = false;
            spawned += 1;
            addObj(o.oid);
            reenter();
            app.dirty = true;
        },
        LT_SHATTER => blk: { // its prepared pieces take its place (object.shatter ... impact)
            const oi = target(k, 0) orelse break :blk;
            _ = @import("rbody.zig").shatterObj(scene.objects[oi].oid);
        },
        LT_DESTROY => blk: {
            const oi = target(k, 0) orelse break :blk;
            scene.objects[oi].visible = false;
            scene.objects[oi].selected = false;
            kill(scene.objects[oi].oid);
            app.dirty = true;
        },
        LT_ACTION => blk: {
            const nm = vname(k, 0) orelse break :blk;
            const act = actionFind(nm) orelse break :blk;
            const so = self() orelse break :blk;
            layerPlay(act, scene.objects[so].oid, @import("anim.zig").frame, pval(k, 1));
        },
        LT_IMPULSE => blk: {
            const v = input(k, 1);
            const oi = target(k, 0) orelse break :blk;
            _ = @import("rbody.zig").impulse(scene.objects[oi].oid, v);
        },
        LT_VIS => blk: {
            const v = input(k, 1)[0];
            const oi = target(k, 0) orelse break :blk;
            show(oi, v);
        },
        LT_SEND => blk: {
            const nm = vname(k, 0) orelse break :blk;
            var to: u32 = 0; // everyone
            if (vname(k, 1)) |tn| {
                const ti = scene.find(tn) orelse break :blk;
                to = scene.objects[ti].oid;
            }
            const v = input(k, 1)[0];
            if (mqn >= MAXQ) break :blk;
            // (the name's 16 bytes as the record holds them)
            const slot: usize = @intCast(cvtt(pval(k, 0)) - 1);
            mq[mqn] = .{ .name = rec[TR_STR + slot * STR_SZ ..][0..16].*, .to = to, .value = v };
            _ = nm;
            mqn += 1;
            msgs +%= 1;
        },
        LT_SETVAR => blk: {
            const v = input(k, 1);
            const vi: u32 = @bitCast(cvtt(pval(k, 0)));
            if (vi >= 8) break :blk;
            const x = &inst().vars[vi];
            x.* = if (cvtt(pval(k, 1)) != 0) v + x.* else v; // set / add
        },
        LT_BRANCH => {
            const c = input(k, 1)[0];
            if (!(c > 0.5)) then = 1;
        },
        else => {},
    }
    runFrom(k, then);
}

/// lg_reenter: the running graph's record again.
fn reenter() void {
    if (nt.get(inst().tree)) |r| rec = r;
}

/// lg_show: visible when > 0.5.
fn show(oi: usize, v: f32) void {
    const o = &scene.objects[oi];
    if (v > 0.5) o.visible = true else {
        o.visible = false;
        o.selected = false;
    }
    app.dirty = true;
}

/// lg_kill: its graphs stop (destroyed).
fn kill(oid: u32) void {
    for (tab[0..n]) |*x| {
        if (x.obj == oid) x.flags |= 2;
    }
}

const Prop = enum { x, y, z, rx, ry, rz, sx, sy, sz, visible };
/// lg_prop: a property by name.
fn prop(nm: []const u8) ?Prop {
    return std.meta.stringToEnum(Prop, nm);
}
fn setProp(oi: usize, p: Prop, v: f32) void {
    const o = &scene.objects[oi];
    switch (p) {
        .x, .y, .z => o.loc[@intFromEnum(p)] = v,
        .rx, .ry, .rz => {
            var r = o.radians();
            r[@intFromEnum(p) - 3] = v;
            o.setRadians(r);
        },
        .sx, .sy, .sz => o.scl[@intFromEnum(p) - 6] = v,
        .visible => return show(oi, v),
    }
    app.dirty = true;
}
fn getProp(oi: usize, p: Prop) f32 {
    const o = &scene.objects[oi];
    return switch (p) {
        .x, .y, .z => o.loc[@intFromEnum(p)],
        .rx, .ry, .rz => o.radians()[@intFromEnum(p) - 3],
        .sx, .sy, .sz => o.scl[@intFromEnum(p) - 6],
        .visible => if (o.visible) 1 else 0,
    };
}

/// an_action_find: the action of this name (its number, 1..).
fn actionFind(nm: []const u8) ?u32 {
    const an = @import("anim.zig");
    const b = an.cur orelse return null;
    for (b.actions(), 0..) |*a, i| {
        if (std.mem.eql(u8, std.mem.sliceTo(&a.name, 0), nm)) return @intCast(i + 1);
    }
    return null;
}

/// an_layer_play: the action plays on the object from this frame (its layer
/// again if it has one; a new one replacing at full influence), then the frame.
fn layerPlay(act: u32, oid: u32, f: f32, repeat0: f32) void {
    const an = @import("anim.zig");
    const repeat = if (repeat0 > 1.0) repeat0 else 1.0; // (maxss)
    const b = an.own(0) orelse return;
    var l: ?*an.Layer = null;
    for (b.h.lay[0..b.h.nlay]) |*x| {
        if (x.act == act and x.target == oid) {
            l = x;
            break;
        }
    }
    if (l == null) {
        if (b.h.nlay >= an.MAXL) return;
        b.h.lay[b.h.nlay] = .{ .act = act, .target = oid, .start = 0, .infl = 1, .mode = 0, .repeat = 1, .mute = 0 };
        l = &b.h.lay[b.h.nlay];
        b.h.nlay += 1;
    }
    l.?.start = f;
    l.?.repeat = repeat;
    l.?.mute = 0;
    an.apply(an.frame);
}

/// lg_deliver: the messages sent this step, to every graph listening (or the
/// one object); messages sent meanwhile too, up to 256.
fn deliver() void {
    var m: u32 = 0;
    while (m < mqn) : (m += 1) {
        const n0 = n;
        var i: u32 = 0;
        while (i < n0) : (i += 1) {
            const in = enter(i) orelse continue;
            if (mq[m].to != 0 and mq[m].to != in.obj) continue;
            ctx_v1 = mq[m].value;
            var b: u32 = 1;
            while (in.flags & 2 == 0 and b <= nt.nodes(rec)) : (b += 1) {
                if (ptype(b) != LT_MSG) continue;
                const nm = vname(b, 0) orelse continue;
                if (!std.mem.eql(u8, nm, std.mem.sliceTo(&mq[m].name, 0))) continue;
                ctx_v1 = mq[m].value; // (the value again: a chain may have sent others)
                fire(b);
            }
        }
    }
    mqn = 0;
}

// --- data --------------------------------------------------------------------------------------

/// lg_input: input i (0..2) of node k: its constant, or what the linked output gives.
fn input(k: u32, i: usize) V {
    const p = nodeOff(k) + nt.ND_IN + i * 16;
    const l = nt.rd32(rec, p);
    if (l == 0) return .{ nt.rdf(rec, p + 4), nt.rdf(rec, p + 8), nt.rdf(rec, p + 12), 0 };
    const c = l & 0xffff;
    const out = (l >> 16) & 0xff;
    if (c == 0 or c > nt.nodes(rec)) return @splat(0);
    const t = ptype(c);
    if (t <= LT_MSG) { // an event: the one firing gives its outputs
        if (c != ctx_node) return @splat(0);
        const v = if (out == 1) ctx_v1 else if (out == 2) ctx_v2 else return @splat(0);
        return andXyz(splat(v));
    }
    if (t == LT_FIELD or (t >= LT_VAR and t <= LT_GETP)) return data(c, out);
    return @splat(0);
}

/// lg_data: a data node's output.
fn data(k: u32, out: u32) V {
    if (depth >= 64) return @splat(0);
    depth += 1;
    defer depth -= 1;
    return andXyz(dataRaw(k, out) orelse return @splat(0));
}

/// (null: .Lld_zero, before the mask; Variable's comes whole)
fn dataRaw(k: u32, out: u32) ?V {
    switch (ptype(k)) {
        LT_FIELD => { // the pull at Point: Force, its Size
            const p = input(k, 0);
            const f = @import("fields.zig").sample(.{ p[0], p[1], p[2] });
            const v = V{ f[0], f[1], f[2], 0 };
            if (out == 0) return v;
            return splat(@sqrt(dot(v, v)));
        },
        LT_VAR => {
            const vi: u32 = @bitCast(cvtt(pval(k, 0)));
            if (vi >= 8) return @splat(0);
            return inst().vars[vi];
        },
        LT_GETP => {
            const oi = target(k, 1) orelse return null;
            const nm = vname(k, 0) orelse return null;
            const p = prop(nm) orelse return null;
            return splat(getProp(oi, p));
        },
        LT_INFO => return info(k),
        LT_MATH => return math(k),
        else => return @splat(0),
    }
}

fn info(k: u32) ?V {
    const pl = play.state();
    switch (cvtt(pval(k, 0))) {
        0 => return splat(time),
        1 => return splat(dt),
        7 => return splat(@import("anim.zig").frame),
        2 => {
            const oi = self() orelse return null;
            return locV(oi);
        },
        3 => {
            const oi = self() orelse return null;
            const r = scene.objects[oi].radians();
            return V{ r[0], r[1], r[2], 0 } * splat(57.29578);
        },
        4 => return inst().start,
        5 => return pl.pos,
        6 => {
            const oi = self() orelse return null;
            const d = andXyz(andXyz(locV(oi)) - pl.pos);
            return splat(@sqrt(dot(d, d)));
        },
        8 => { // a hash of the step, the node, the object
            var v: V = @splat(0);
            inline for (0..3) |q| {
                var e: u32 = steps *% 73856093;
                e ^= k *% 19349663;
                e ^= cur *% 83492791;
                e ^= (@as(u32, @intCast(q)) * 9 + 1) *% 0x27d4eb2d;
                e ^= e >> 15;
                e *%= 0x2c1b3c6d;
                e ^= e >> 12;
                e *%= 0x297a2d39;
                e ^= e >> 15;
                e >>= 8;
                v[q] = @as(f32, @floatFromInt(e)) * 5.9604645e-8;
            }
            return v;
        },
        else => return null,
    }
}

fn math(k: u32) ?V {
    const a = input(k, 0);
    const b = input(k, 1);
    const op: u32 = @bitCast(cvtt(pval(k, 0)));
    if (op > 17) return null;
    const one: V = .{ 1, 1, 1, 0 };
    const half: V = @splat(0.5);
    return switch (op) {
        0 => a + b,
        1 => a - b,
        2 => a * b,
        3 => blk: { // (by 0: 0; NaN: 0)
            const ok = !(@abs(b) < @as(V, @splat(1.0e-4)));
            const q = mask(ok, a / b);
            break :blk mask(q == q, q);
        },
        4 => minps(a, b),
        5 => maxps(a, b),
        6, 7 => blk: {
            var r: V = @splat(0);
            inline for (0..3) |q| r[q] = ax.sincos32(a[q])[op - 6];
            break :blk r;
        },
        8 => mask(b < a, one),
        9 => mask(a < b, one),
        10 => mask(@abs(a - b) < @as(V, @splat(1.0e-4)), one),
        11 => mask(!((a < half) | (b < half)), one),
        12 => mask((half < a) | (half < b), one),
        13 => mask(a < half, one),
        14 => @abs(a),
        15 => splat(@sqrt(dot(andXyz(a), andXyz(a)))),
        16 => blk: {
            const d = andXyz(a - b);
            break :blk splat(@sqrt(dot(d, d)));
        },
        else => a * splat(b[0]),
    };
}

// --- overlaps ----------------------------------------------------------------------------------

/// lg_overlap: the running object's box (grown by the margin) meets the
/// player's (no name) or the named object's.
fn overlap(k: u32) bool {
    const oi = self() orelse return false;
    if (!scene.objects[oi].visible) return false;
    var a = objBox(oi);
    const m = andXyz(splat(pval(k, 2)));
    a[0] = a[0] - m;
    a[1] = a[1] + m;
    var b: [2]V = undefined;
    if (vname(k, 0)) |nm| {
        const j = scene.find(nm) orelse return false;
        if (!scene.objects[j].visible) return false;
        b = objBox(j);
    } else {
        const pl = play.state();
        if (pl.on != 1) return false;
        const r = andXyz(splat(pl.radius));
        var lo = pl.pos - r;
        lo[1] = pl.pos[1];
        var hi = pl.pos + r;
        hi[1] = pl.pos[1] + pl.height;
        b = .{ lo, hi };
    }
    inline for (0..3) |c| {
        if (a[1][c] < b[0][c] or b[1][c] < a[0][c]) return false;
    }
    return true;
}

/// lg_obj_box: its mesh's box in the world (a point at its place without a mesh).
pub fn objBox(oi: usize) [2]V {
    const me = @import("mods.zig").of(oi);
    if (me == null or me.?.tris.len == 0) {
        const p = andXyz(locV(oi));
        return .{ p, p };
    }
    const mt = @import("fields.zig").objMatrix(oi);
    const lo = me.?.lo;
    const hi = me.?.hi;
    var bmin: V = .{ 1.0e30, 1.0e30, 1.0e30, 0 };
    var bmax: V = .{ -1.0e30, -1.0e30, -1.0e30, 0 };
    for (0..8) |c| {
        const p: V = .{ if (c & 1 != 0) hi[0] else lo[0], if (c & 2 != 0) hi[1] else lo[1], if (c & 4 != 0) hi[2] else lo[2], 1 };
        var q: V = @splat(0);
        inline for (0..3) |r| q[r] = dot(p, .{ mt[r * 4], mt[r * 4 + 1], mt[r * 4 + 2], mt[r * 4 + 3] });
        bmin = minps(bmin, q);
        bmax = maxps(bmax, q);
    }
    return .{ bmin, bmax };
}

const Impl = ops.Impl;
pub const list = .{
    .{ "logic.new", Impl{ .run = opNew } },
    .{ "logic.attach", Impl{ .run = opAttach } },
    .{ "logic.node", Impl{ .run = opNode } },
    .{ "logic.name", Impl{ .run = opName } },
};

test "logic: defaults, names, types" {
    try std.testing.expectEqual(@as(?u32, 25), typeIndex("field"));
    try std.testing.expectEqual(@as(?u32, null), typeIndex("Field"));
    const d: [13]f32 = @bitCast(defaults[LT_KEY - 1]);
    try std.testing.expectEqual(@as(f32, 18), d[0]);
    var r: nt.Rec = @splat(0);
    nt.wr32(&r, nt.GR_N, 1);
    nt.wr32(&r, nt.nodeAt(1), LT_SEND);
    nt.wrf(&r, nt.nodeAt(1) + nt.ND_P, 3);
    nt.wrf(&r, nt.nodeAt(1) + nt.ND_P + 4, 31);
    try std.testing.expectEqual(@as(u64, 4), namesUsed(&r));
    @memcpy(r[TR_STR + 2 * 16 ..][0..4], "ping");
    try std.testing.expectEqualStrings("ping", nameOf(&r, 3).?);
    try std.testing.expectEqual(@as(?[]const u8, null), nameOf(&r, 31));
}
