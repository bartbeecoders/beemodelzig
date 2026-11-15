// The CAD document (cad.s): scene units and parameters, and the feature
// records (feature.zig replays them).
//
// One reference-counted block, copy-on-write like the light probes, so undo
// steps keep the document they saw. Parameters are name = expression
// (animexpr.zig, the port of expr.s); values are evaluated on demand with a
// cache tied to the block and a generation counter, and a parameter met again
// while it is being evaluated is a cycle. Lengths are kept in scene units:
// the unit says how many millimetres one scene unit is (1000 by default:
// metres).
//
// ---- The API other modules use (stable) ---------------------------------------------
//   unitMm() f64                     cad_unit_mm: mm per scene unit
//   unitName() ?[]const u8           cad_unit_name: "mm" "cm" "m" "in", null for another scale
//   paramCount() usize               param_count
//   paramName(i) / paramExpr(i)      the record's name and expression text
//   paramFind(name) ?usize           param_find
//   paramValue(i) ?f64               param_value (null: it fails; expr.err says why
//                                     the first time, nothing when cached)
//   paramLookup(name) ?f64           param_lookup (null: no such parameter)
//   eval(text) ?f64                  expr_eval with the parameters and scene units
//                                     (null: expr.err says why)
//   paramSet(name, expr) bool        param_set (false: expr.err says why; nothing changed)
//   version                          moves whenever the document changes (caches key on it)
//   rebuild()                        cad_rebuild: what follows parameters and units
//                                     (sketches, features) re-evaluates; add yours there
//   fmtVal3(buf, v) []const u8        fmt_val3: three decimals at most, as the original's logs
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const xp = @import("animexpr.zig");

pub const expr = xp;

pub const MAX_PARAMS = 64;
pub const PR_SZ = 128;
pub const PR_NAME = 0; // 24
pub const PR_EXPR = 24; // 92
pub const PR_VAL = 120; // f64: the last good value (files)
pub const MAX_FEATS = 64;
pub const FT_SZ = 128; // feature.s

pub const Block = struct {
    refs: u32 = 1,
    unit: f64 = 1000.0,
    kernel: u32 = 0,
    np: u32 = 0,
    params: [MAX_PARAMS][PR_SZ]u8 = @splat(@splat(0)),
    nf: u32 = 0,
    feats: [MAX_FEATS][FT_SZ]u8 = @splat(@splat(0)),
    /// per feature: its body (1) / sketch (2) is a file's uid no object has
    /// (kept as it came); else the fields hold object ids (feature.zig)
    fraw: [MAX_FEATS]u8 = @splat(0),
    /// per feature: the persistent uids (scene.Object.uid) its body and sketch
    /// had, so a file keeps them after the object is deleted, as the original
    fuid: [MAX_FEATS][2]u32 = @splat(.{ 0, 0 }),
};

const A = std.heap.page_allocator;

/// The document now (null: none, the defaults).
pub var cur: ?*Block = null;
/// Moves whenever the document changes (cad_gen).
pub var version: u32 = 1;

pub const units_names = [_][]const u8{ "mm", "cm", "m", "in" };
pub const units_mm = [_]f64{ 1.0, 10.0, 1000.0, 25.4 };
pub const units_labels = [_][]const u8{ "Millimetres", "Centimetres", "Metres", "Inches" };

const e_cycle = "the parameters refer to each other in a cycle";
const e_pname = "a parameter name is a letter or _, then letters, digits or _";
const e_pfull = "the scene holds 64 parameters";
const e_pfunc = "that name belongs to a function or constant";

const reserved = [_][]const u8{ "pi", "e", "sin", "cos", "tan", "sqrt", "abs", "min", "max" };

// ---- the block ----------------------------------------------------------------------

fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

/// After the document changed (edit, undo, load): the units, the cache.
pub fn sync() void {
    version +%= 1;
    xp.unit_mm = unitMm();
    xp.param_lookup = paramLookup;
    app.dirty = true;
}

/// A new scene: no document.
pub fn reset() void {
    unref(cur);
    cur = null;
    sync();
}

/// cad_cow: the block, ours to change (made on first use); null without memory.
pub fn own() ?*Block {
    if (cur) |b| {
        if (b.refs == 1) return b;
    }
    const nb = A.create(Block) catch return null;
    if (cur) |b| nb.* = b.* else nb.* = .{};
    nb.refs = 1;
    unref(cur);
    cur = nb;
    return nb;
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}

pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    const changed = b != cur;
    unref(cur);
    cur = b;
    if (changed) sync();
}

fn sameBlock(a: ?*const Block, b: ?*const Block) bool {
    if (a == b) return true;
    const d = Block{};
    const x = a orelse &d;
    const y = b orelse &d;
    if (x.unit != y.unit or x.kernel != y.kernel or x.np != y.np or x.nf != y.nf) return false;
    for (x.params[0..x.np], y.params[0..y.np]) |*p, *q| {
        if (!std.mem.eql(u8, p, q)) return false;
    }
    for (x.feats[0..x.nf], y.feats[0..y.nf]) |*p, *q| {
        if (!std.mem.eql(u8, p, q)) return false;
    }
    if (!std.mem.eql(u8, x.fraw[0..x.nf], y.fraw[0..y.nf])) return false;
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(x.fuid[0..x.nf]), std.mem.sliceAsBytes(y.fuid[0..y.nf]))) return false;
    return true;
}

/// Is the document the one this snapshot saw (its contents)?
pub fn same(b: ?*const Block) bool {
    return sameBlock(cur, b);
}

// ---- units -------------------------------------------------------------------------

/// mm per scene unit.
pub fn unitMm() f64 {
    return if (cur) |b| b.unit else 1000.0;
}

/// "mm" / "cm" / "m" / "in", or null for another scale.
pub fn unitName() ?[]const u8 {
    const u = unitMm();
    for (units_mm, 0..) |x, k| {
        if (u == x) return units_names[k];
    }
    return null;
}

/// cad_kernel: features make B-rep solids.
pub fn kernel() bool {
    return if (cur) |b| b.kernel != 0 else false;
}

// ---- parameters -----------------------------------------------------------------------

pub fn paramCount() usize {
    return if (cur) |b| b.np else 0;
}

fn rec(i: usize) *[PR_SZ]u8 {
    return &cur.?.params[i];
}

pub fn paramName(i: usize) []const u8 {
    return std.mem.sliceTo(rec(i)[PR_NAME .. PR_NAME + 24], 0);
}

pub fn paramExpr(i: usize) []const u8 {
    return std.mem.sliceTo(rec(i)[PR_EXPR .. PR_EXPR + 92], 0);
}

/// The value it had when last set (PR_VAL: what files keep).
pub fn paramSaved(i: usize) f64 {
    return @bitCast(std.mem.readInt(u64, rec(i)[PR_VAL..][0..8], .little));
}

pub fn featCount() usize {
    return if (cur) |b| b.nf else 0;
}

pub fn paramFind(name: []const u8) ?usize {
    for (0..paramCount()) |i| {
        if (std.mem.eql(u8, paramName(i), name)) return i;
    }
    return null;
}

// the cache: for this block at this version
var pc_doc: ?*Block = null;
var pc_ver: u32 = 0;
var pc_state: [MAX_PARAMS]u8 = @splat(0); // 0 unknown, 1 busy, 2 done, 3 failed
var pc_val: [MAX_PARAMS]f64 = @splat(0);

/// The value of parameter i (null: it fails, and expr.err says why).
pub fn paramValue(i: usize) ?f64 {
    if (cur != pc_doc or version != pc_ver) {
        pc_doc = cur;
        pc_ver = version;
        pc_state = @splat(0);
    }
    switch (pc_state[i]) {
        2 => return pc_val[i],
        1 => {
            if (xp.err == null) xp.err = e_cycle;
            return null;
        },
        // (cad.s .Lpv_fail: a failure met again says nothing, so what uses it
        // takes 0 as its value and goes on, as the original)
        3 => return null,
        else => {},
    }
    pc_state[i] = 1;
    // (the text is copied: an evaluation can change nothing, but the cache can be reset under it)
    var t: [92]u8 = undefined;
    const s = paramExpr(i);
    @memcpy(t[0..s.len], s);
    // (expr_eval: nested in another expression it keeps that one's error,
    // and any error so far fails it, as the original: an expression that
    // failed before it asked for this parameter leaves it failed, value 0,
    // until the document changes)
    const r = xp.evaluate(t[0..s.len]);
    if (r.ok) {
        pc_state[i] = 2;
        pc_val[i] = r.v;
        return r.v;
    }
    pc_state[i] = 3;
    return null;
}

/// param_lookup: a parameter's value, null when there is none by that name.
/// One that fails counts as known (0); it sets expr.err only when it is first
/// evaluated here (param_value's cache: a failure met again says nothing).
pub fn paramLookup(name: []const u8) ?f64 {
    const i = paramFind(name) orelse return null;
    return paramValue(i) orelse 0;
}

/// An expression with the parameters, in scene units (null: expr.err says why).
pub fn eval(text: []const u8) ?f64 {
    xp.param_lookup = paramLookup;
    xp.unit_mm = unitMm();
    const r = xp.evaluate(text);
    return if (r.ok) r.v else null;
}

/// [A-Za-z_][A-Za-z0-9_]* (1..23), not a function or constant.
fn validName(s: []const u8) bool {
    for (s, 0..) |c, k| {
        const ok = (c | 0x20) -% 'a' < 26 or c == '_' or (k > 0 and c -% '0' < 10);
        if (!ok or k + 1 > 23) {
            xp.err = e_pname;
            return false;
        }
    }
    if (s.len == 0) {
        xp.err = e_pname;
        return false;
    }
    for (reserved) |r| {
        if (std.mem.eql(u8, r, s)) {
            xp.err = e_pfunc;
            return false;
        }
    }
    return true;
}

/// param_set: define or change a parameter; false (expr.err says why) when the
/// name is wrong or any parameter would fail with it: then nothing changed.
pub fn paramSet(name: []const u8, text: []const u8) bool {
    xp.err = null;
    if (!validName(name)) return false;
    const b = own() orelse return false;
    var ix = paramFind(name);
    const had = ix != null;
    if (ix == null) {
        if (b.np >= MAX_PARAMS) {
            xp.err = e_pfull;
            return false;
        }
        ix = b.np;
        b.np += 1;
    }
    const r = &b.params[ix.?];
    const old = r.*;
    r.* = @splat(0);
    const nn = @min(name.len, 23);
    @memcpy(r[0..nn], name[0..nn]);
    const tn = @min(std.mem.indexOfScalar(u8, text, 0) orelse text.len, 91);
    @memcpy(r[PR_EXPR..][0..tn], text[0..tn]);
    sync(); // every parameter must still work
    var k: usize = 0;
    while (k < b.np) : (k += 1) {
        xp.err = null;
        const v = paramValue(k) orelse {
            const why = xp.err;
            if (had) r.* = old else b.np -= 1;
            sync();
            xp.err = why;
            return false;
        };
        std.mem.writeInt(u64, b.params[k][PR_VAL..][0..8], @bitCast(v), .little);
    }
    return true;
}

/// param_remove: the later ones move down.
fn paramRemove(i: usize) void {
    const b = own() orelse return;
    var k = i;
    while (k + 1 < b.np) : (k += 1) b.params[k] = b.params[k + 1];
    b.np -= 1;
    sync();
}

/// cad_rebuild (sketchobj.s): what is made from the parameters and units follows.
/// The sketches and the features add themselves here.
pub var rebuild_hook: ?*const fn () void = null;

pub fn rebuild() void {
    if (rebuild_hook) |h| h() else @import("skobj.zig").rebuildAll();
}

// ---- files: CADD = unit (f64), count, records, features, the kernel switch ---------

pub fn writeChunk(b: anytype) void {
    var u: [8]u8 = undefined;
    std.mem.writeInt(u64, &u, @bitCast(unitMm()), .little);
    b.bytes(&u);
    b.u32_(@intCast(paramCount()));
    for (0..paramCount()) |i| b.bytes(rec(i));
    b.u32_(@intCast(featCount()));
    for (0..featCount()) |i| {
        var r: [FT_SZ]u8 = undefined;
        @import("feature.zig").fileRecord(i, &r); // (object ids as the file's uids)
        b.bytes(&r);
    }
    b.u32_(@intFromBool(kernel()));
}

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// cad_read, after reset (a new scene); a damaged chunk leaves the defaults.
/// False when the chunk was there but not taken whole.
pub fn readChunk(d: []const u8) bool {
    if (d.len < 12) return false;
    const n = rd32(d, 8);
    if (n > MAX_PARAMS) return false;
    if (12 + n * PR_SZ > d.len) return false;
    const b = own() orelse return false;
    const u: f64 = @bitCast(std.mem.readInt(u64, d[0..8], .little));
    if (u > 0) b.unit = u; // (a sane unit; NaN and negatives are not)
    b.np = n;
    for (0..n) |k| {
        @memcpy(&b.params[k], d[12 + k * PR_SZ ..][0..PR_SZ]);
        b.params[k][23] = 0; // names and texts terminated
        b.params[k][PR_EXPR + 91] = 0;
    }
    var whole = true;
    const c = n * PR_SZ;
    // the features (newer files)
    blk: {
        if (c + 16 > d.len) break :blk;
        const nf = rd32(d, c + 12);
        if (nf > MAX_FEATS) {
            whole = false;
            break :blk;
        }
        if (c + nf * FT_SZ + 16 > d.len) {
            whole = false;
            break :blk;
        }
        b.nf = nf;
        for (0..nf) |k| @memcpy(&b.feats[k], d[c + 16 + k * FT_SZ ..][0..FT_SZ]);
        // the kernel switch (newer files)
        if (c + nf * FT_SZ + 20 > d.len) break :blk;
        b.kernel = rd32(d, c + nf * FT_SZ + 16) & 1;
    }
    sync();
    return whole;
}

// ---- fmt_val3 -------------------------------------------------------------------------

/// fmt_val3: a float with three decimals at most, as the original's logs.
pub fn fmtVal3(buf: []u8, v0: f32) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var v = v0;
    if (!(v >= 0)) {
        w.writeByte('-') catch {};
        v = 0 - v;
    }
    const x = v * 1000 + 0.5;
    // cvttss2si: out of range or NaN is the minimum, here taken unsigned
    const k: u32 = if (x >= -2147483648.0 and x < 2147483648.0) @bitCast(@as(i32, @intFromFloat(x))) else 0x80000000;
    w.print("{d}", .{k / 1000}) catch {};
    var f = k % 1000;
    if (f != 0) {
        var n: usize = 3;
        while (n > 1 and f % 10 == 0) : (n -= 1) f /= 10;
        w.print(".{d:0>[1]}", .{ f, n }) catch {};
    }
    return w.buffered();
}

// ---- the operators ---------------------------------------------------------------------

var cw_name: [31]u8 = undefined;
var cw_name_n: usize = 0;
var cw_expr: [95]u8 = undefined;
var cw_expr_n: usize = 0;

/// split_arg: cw_name = the first word, cw_expr = the rest ("wall=2mm",
/// "wall = 2mm", a form's "\"10*wall + 2mm\"" unquoted); false when none.
fn splitArg(arg: []const u8) bool {
    var i: usize = 0;
    const at = struct {
        fn f(s: []const u8, k: usize) u8 {
            return if (k < s.len) s[k] else 0;
        }
    }.f;
    while (at(arg, i) == ' ') i += 1;
    cw_name_n = 0;
    while (true) : (i += 1) {
        const c = at(arg, i);
        if (c == 0 or c == ' ' or c == '=') break;
        if (cw_name_n < 30) {
            cw_name[cw_name_n] = c;
            cw_name_n += 1;
        }
    }
    if (cw_name_n == 0) return false;
    while (at(arg, i) == ' ' or at(arg, i) == '=') i += 1;
    cw_expr_n = 0;
    while (cw_expr_n < 94) : (cw_expr_n += 1) {
        const c = at(arg, i + cw_expr_n);
        if (c == 0) break;
        cw_expr[cw_expr_n] = c;
    }
    if (cw_expr_n > 0 and cw_expr[0] == '"') {
        std.mem.copyForwards(u8, cw_expr[0 .. cw_expr_n - 1], cw_expr[1..cw_expr_n]);
        cw_expr_n -= 1;
        if (cw_expr_n > 0 and cw_expr[cw_expr_n - 1] == '"') cw_expr_n -= 1;
    }
    return true;
}

fn nameW() []const u8 {
    return cw_name[0..cw_name_n];
}
fn exprW() []const u8 {
    return cw_expr[0..cw_expr_n];
}

fn sayErr(name: []const u8) void {
    app.log("  parameter: {s}: {s}", .{ name, xp.err orelse "" });
}

pub fn opParamSet() void {
    const ops = @import("ops.zig");
    if (!splitArg(ops.arg) or cw_expr_n == 0) return app.log("  param.set <name> <expression>  (e.g. wall 2mm, width 10*wall)", .{});
    if (!paramSet(nameW(), exprW())) return sayErr(nameW());
    var vb: [32]u8 = undefined;
    const v = paramValue(paramFind(nameW()).?) orelse 0;
    app.log("  parameter {s} = {s}  ({s})", .{ nameW(), exprW(), fmtVal3(&vb, @floatCast(v)) });
    rebuild();
}

pub fn opParamRemove() void {
    const ops = @import("ops.zig");
    const got = splitArg(ops.arg);
    if (!got) cw_name_n = 0;
    const i = (if (got) paramFind(nameW()) else null) orelse return app.log("  no parameter named {s}", .{nameW()});
    paramRemove(i);
    app.log("  parameter removed: {s}", .{nameW()});
    rebuild();
    // whatever used it now fails: say so
    for (0..paramCount()) |k| {
        xp.err = null;
        if (paramValue(k) == null) sayErr(paramName(k));
    }
}

pub fn opParamList() void {
    if (paramCount() == 0) return app.log("  no parameters", .{});
    for (0..paramCount()) |i| {
        var vb: [32]u8 = undefined;
        const v = paramValue(i) orelse 0;
        app.log("  parameter {s} = {s}  ({s})", .{ paramName(i), paramExpr(i), fmtVal3(&vb, @floatCast(v)) });
    }
}

pub fn opSceneUnits() void {
    const ops = @import("ops.zig");
    if (splitArg(ops.arg)) {
        for (units_names, 0..) |u, k| {
            if (!std.mem.eql(u8, u, nameW())) continue;
            const b = own() orelse break;
            b.unit = units_mm[k];
            sync();
            rebuild();
            return app.log("  scene units: {s}", .{u});
        }
    }
    app.log("  scene.units mm|cm|m|in", .{});
}

pub fn opKernel() void {
    const ops = @import("ops.zig");
    if (splitArg(ops.arg)) {
        const on = std.mem.eql(u8, nameW(), "on");
        if (on or std.mem.eql(u8, nameW(), "off")) {
            if (own()) |b| {
                b.kernel = @intFromBool(on);
                sync();
                rebuild();
                return app.log("  B-rep kernel: {s}", .{if (on) "on" else "off"});
            }
        }
    }
    app.log("  cad.kernel on|off", .{});
}

pub fn isKernel() bool {
    return kernel();
}

// ---- tests ----------------------------------------------------------------------------

test "parameters: values, cycles, failures, files" {
    const T = std.testing;
    reset();
    try T.expect(paramSet("wall", "2mm"));
    try T.expectEqual(@as(f64, 0.002), paramValue(0).?);
    try T.expect(paramSet("width", "10*wall + 2mm"));
    try T.expectApproxEqAbs(@as(f64, 0.022), paramValue(1).?, 1e-15);
    // a cycle is refused and changes nothing
    try T.expect(!paramSet("wall", "width"));
    try T.expectEqualStrings(e_cycle, xp.err.?);
    try T.expectEqualStrings("2mm", paramExpr(0));
    try T.expect(!paramSet("1x", "3"));
    try T.expectEqualStrings(e_pname, xp.err.?);
    try T.expect(!paramSet("sin", "3"));
    try T.expectEqualStrings(e_pfunc, xp.err.?);
    try T.expect(!paramSet("x", "nosuch"));
    try T.expectEqual(@as(usize, 2), paramCount());
    // units: lengths follow
    cur.?.unit = 1.0;
    sync();
    try T.expectApproxEqAbs(@as(f64, 22), paramValue(1).?, 1e-12);
    try T.expectEqualStrings("mm", unitName().?);
    // what uses a failing one fails too when it meets the failure first ...
    paramRemove(0);
    try T.expect(paramValue(0) == null);
    // ... but takes 0 for one already known to fail (cad.s .Lpv_fail), and an
    // error before it fails a parameter met afterwards (expr_eval keeps it)
    reset();
    try T.expect(paramSet("wall", "2mm"));
    try T.expect(paramSet("width", "10*wall + 2mm"));
    try T.expect(paramSet("ang", "asin(0.5)"));
    cur.?.params[0] = @splat(0);
    @memcpy(cur.?.params[0][0..4], "wall");
    @memcpy(cur.?.params[0][PR_EXPR..][0..5], "q+ang");
    sync();
    try T.expect(paramValue(0) == null);
    try T.expectApproxEqAbs(@as(f64, 0.002), paramValue(1).?, 1e-15);
    try T.expect(paramValue(2) == null);
    sync(); // in another order: width meets wall's failure first
    try T.expect(paramValue(1) == null);
    try T.expectEqualStrings(xp.e_name, xp.err.?);
    try T.expect(paramValue(2) == null);
    reset();
    try T.expect(unitName() != null and std.mem.eql(u8, unitName().?, "m"));
}

test "fmt_val3" {
    var b: [32]u8 = undefined;
    const T = std.testing;
    try T.expectEqualStrings("0.002", fmtVal3(&b, 0.002));
    try T.expectEqualStrings("2", fmtVal3(&b, 2));
    try T.expectEqualStrings("-1.5", fmtVal3(&b, -1.5));
    try T.expectEqualStrings("0.1", fmtVal3(&b, 0.1));
    try T.expectEqualStrings("12.346", fmtVal3(&b, 12.3456));
}

test "a feature's objects deleted: files keep their uids, new objects take later ones" {
    const T = std.testing;
    const scene = @import("scene.zig");
    const feature = @import("feature.zig");
    scene.init();
    defer scene.reset();
    // Camera 1, Light 2, Cube 3; then a body (4) and another (5)
    const a = scene.add(.cube).?;
    const b = scene.add(.cube).?;
    try T.expectEqual(@as(u32, 4), scene.objects[a].uid);
    try T.expectEqual(@as(u32, 6), scene.uid_next);
    var r: [FT_SZ]u8 = @splat(0);
    std.mem.writeInt(u32, r[0..4], feature.T_PAD, .little);
    std.mem.writeInt(u32, r[4..8], scene.objects[a].oid, .little);
    _ = feature.add(&r);
    std.mem.writeInt(u32, r[4..8], scene.objects[b].oid, .little);
    _ = feature.add(&r);
    scene.remove(a);
    _ = scene.add(.cube).?; // (uid 6: not the deleted one's)
    var out: [FT_SZ]u8 = undefined;
    feature.fileRecord(0, &out);
    try T.expectEqual(@as(u32, 4), std.mem.readInt(u32, out[4..8], .little));
    feature.fileRecord(1, &out);
    try T.expectEqual(@as(u32, 5), std.mem.readInt(u32, out[4..8], .little));
    try T.expectEqual(@as(u32, 6), scene.objects[scene.count - 1].uid);
    try T.expectEqual(@as(u32, 7), scene.uid_next);
}
