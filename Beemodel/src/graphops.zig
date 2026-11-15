// Editing shader graphs (graph.s, matinst.s, matlib.s): nodes, links, pins;
// material instances and their parameters; the procedural presets; the graph of
// a texture set. Evaluation is in shgraph.zig, the commands in graphcmds.zig.
const std = @import("std");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const Material = material.Material;

const NFLAGS = sg.NFLAGS_AT;
const OVR: u8 = 2; // NE_NFLAGS: an instance overrides it
const OUTPOS = 152 - material.FILE_PART;

pub const type_names = [_][]const u8{ "image", "noise", "checker", "gradient", "mix", "ramp", "math", "bump", "normalmap", "texcoord", "position", "normal", "camera", "vcolor", "time", "constant", "color", "fresnel", "vmath", "separate", "combine", "mapping", "panner", "rotator", "voronoi", "hsv", "invert", "brightcon", "desaturate", "gamma", "blackbody", "brick", "wave", "whitenoise", "triplanar", "reroute", "scalarparam", "vectorparam", "textureparam", "fninput", "fnoutput", "fncall" };
pub const type_titles = [_][]const u8{ "Texture Sample", "Noise Texture", "Checker Texture", "Gradient Texture", "Mix", "Color Ramp", "Math", "Bump", "Normal Map", "Texture Coordinate", "Position", "Normal", "Camera Vector", "Vertex Color", "Time", "Constant", "Color", "Fresnel", "Vector Math", "Separate", "Combine", "Mapping", "Panner", "Rotator", "Voronoi Texture", "Hue/Saturation", "Invert", "Bright/Contrast", "Desaturation", "Gamma", "Blackbody", "Brick Texture", "Wave Texture", "White Noise", "Triplanar Sample", "Reroute", "Scalar Parameter", "Vector Parameter", "Texture Parameter", "Function Input", "Function Output", "Material Function" };
/// per type: p0..p3, the inputs' values (3 each)
pub const defaults = [_][13]f32{
    .{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // image
    .{ 4.0, 3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // noise
    .{ 2.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.2, 0.2, 0.2, 0.0, 0.0, 0.0 }, // checker
    .{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // gradient
    .{ 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.8, 0.8, 0.8, 0.2, 0.2, 0.2 }, // mix
    .{ 0.0, 1.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 }, // ramp
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // math
    .{ 1.0, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // bump
    .{ 1.0, 0.0, 0.0, 0.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // normalmap
    .{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // texcoord
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // position
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // normal
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // camera
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // vcolor
    .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // time
    .{ 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // constant
    .{ 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // color
    .{ 5.0, 0.04, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // fresnel
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // vmath
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // separate
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // combine
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 }, // mapping
    .{ 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // panner
    .{ 0.5, 0.5, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // rotator
    .{ 5.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // voronoi
    .{ 0.0, 1.0, 1.0, 1.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // hsv
    .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // invert
    .{ 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // brightcon
    .{ 1.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // desaturate
    .{ 1.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // gamma
    .{ 6500.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // blackbody
    .{ 4.0, 0.03, 0.5, 0.0, 0.0, 0.0, 0.0, 0.6, 0.25, 0.15, 0.8, 0.8, 0.8 }, // brick
    .{ 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // wave
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // whitenoise
    .{ 0.0, 1.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // triplanar
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // reroute
    .{ 0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // scalarparam
    .{ 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // vectorparam
    .{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // textureparam
    .{ 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // fninput
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // fnoutput
    .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, // fncall
};
pub const socket_names = [_][]const u8{ "base", "metallic", "specular", "roughness", "emission", "opacity", "normal", "ao", "clearcoat", "coat_roughness", "transmission", "ior", "mask" };

pub fn typeIndex(nm: []const u8) ?u32 {
    for (type_names, 1..) |t, i| {
        if (std.mem.eql(u8, t, nm)) return @intCast(i);
    }
    return null;
}

fn own(mi: usize) ?*Material {
    const ma = material.get(mi) orelse return null;
    material.version +%= 1;
    return ma;
}

fn isParam(t: u32) bool {
    return t >= 37 and t <= 39;
}

// --- nodes ----------------------------------------------------------------------------

/// A new node of a type (1..): its number (1..), null when the graph is full.
pub fn add(mi: usize, t: u32) ?u32 {
    if (t == 0 or t > type_names.len) return null;
    const ma = own(mi) orelse return null;
    const n = sg.count(ma);
    if (n >= sg.MAX_NODES) return null;
    const nd = &sg.nodesMut(ma)[n];
    nd.* = std.mem.zeroes(sg.Node);
    nd.type = t;
    const d = defaults[t - 1];
    nd.p = d[0..4].*;
    for (&nd.in, 0..) |*i, k| i.v = d[4 + k * 3 ..][0..3].*;
    setCount(ma, n + 1);
    if (isParam(t)) {
        // a parameter's name: "Param n" (n: its count among the parameters,
        // itself too: param_default counts the nodes up to the new one's end)
        var c: u32 = 0;
        for (sg.nodesOf(ma)[0 .. n + 1]) |*x| {
            if (isParam(x.type)) c += 1;
        }
        var b: [24]u8 = undefined;
        setParamName(nd, std.fmt.bufPrint(&b, "Param {d}", .{c}) catch "Param");
    }
    return n + 1;
}

fn setCount(ma: *Material, n: u32) void {
    std.mem.writeInt(u32, ma.graph[0..4], n, .little);
}

/// A parameter's name lives in the constants of its second and third inputs.
pub fn paramName(nd: *const sg.Node, out: *[24]u8) []const u8 {
    const a: *const [12]u8 = @ptrCast(&nd.in[1].v);
    const b: *const [12]u8 = @ptrCast(&nd.in[2].v);
    @memcpy(out[0..12], a);
    @memcpy(out[12..24], b);
    out[23] = 0;
    return std.mem.sliceTo(out, 0);
}

pub fn setParamName(nd: *sg.Node, nm: []const u8) void {
    var b: [24]u8 = @splat(0);
    const n = @min(nm.len, 23);
    @memcpy(b[0..n], nm[0..n]);
    const a: *[12]u8 = @ptrCast(&nd.in[1].v);
    const c: *[12]u8 = @ptrCast(&nd.in[2].v);
    @memcpy(a, b[0..12]);
    @memcpy(c, b[12..24]);
}

/// Slots 1-3 set an input's constant (and unlink it), 4-7 the values.
pub fn setSlot(mi: usize, node: u32, slot: u32, v: []const f32) bool {
    const ma = own(mi) orelse return false;
    if (node == 0 or node > sg.count(ma) or v.len == 0) return false;
    const nd = &sg.nodesMut(ma)[node - 1];
    if (slot >= 1 and slot <= 3) {
        const i = &nd.in[slot - 1];
        i.link = 0;
        i.v = if (v.len >= 3) v[0..3].* else .{ v[0], v[0], v[0] };
        return true;
    }
    if (slot < 4 or slot > 7) return false;
    nd.p[slot - 4] = v[0];
    return true;
}

fn val(mi: usize, node: u32, slot: u32, v: f32) void {
    _ = setSlot(mi, node, slot, &.{v});
}

/// The nodes in evaluation order (every link from an earlier node; among the
/// ready ones the lowest first), links and pins renumbered. False: a loop.
pub fn sortNodes(ma: *Material) bool {
    const n = sg.count(ma);
    const nodes = sg.nodesMut(ma);
    var placed: [sg.MAX_NODES]bool = @splat(false);
    var new_of: [sg.MAX_NODES]u8 = undefined;
    var done: u32 = 0;
    while (done < n) {
        var found = false;
        for (0..n) |i| {
            if (placed[i]) continue;
            var ready = true;
            for (nodes[i].in) |l| {
                const lo = l.link & 0xffff;
                if (lo != 0 and lo - 1 < n and !placed[lo - 1]) ready = false;
            }
            if (ready) {
                placed[i] = true;
                new_of[i] = @intCast(done);
                done += 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    const old_nodes = nodes.*;
    const old_flags: [sg.MAX_NODES]u8 = ma.graph[NFLAGS..][0..sg.MAX_NODES].*;
    for (0..n) |i| {
        nodes[new_of[i]] = old_nodes[i];
        ma.graph[@as(usize, NFLAGS) + new_of[i]] = old_flags[i];
    }
    for (nodes[0..n]) |*nd| {
        for (&nd.in) |*l| {
            const lo = l.link & 0xffff;
            if (lo != 0 and lo - 1 < n) l.link = (l.link & 0xffff0000) | (@as(u32, new_of[lo - 1]) + 1);
        }
    }
    for (sg.pinsMut(ma)[0..sg.NPINS]) |*p| {
        const lo = p.* & 0xffff;
        if (lo != 0 and lo - 1 < n) p.* = (p.* & 0xffff0000) | (@as(u32, new_of[lo - 1]) + 1);
    }
    return true;
}

/// Feed `from`'s output into `to`'s input (1..3): the node fed, renumbered;
/// null: no such nodes, or the link would make a loop (nothing changed).
pub fn link(mi: usize, from: u32, to: u32, input: u32, out: u32) ?u32 {
    const ma = own(mi) orelse return null;
    const n = sg.count(ma);
    if (from == 0 or to == 0 or from == to or from > n or to > n or input == 0 or input > 3 or out >= sg.NOUTS) return null;
    const nodes = sg.nodesMut(ma);
    const slot = &nodes[to - 1].in[input - 1];
    const old = slot.link;
    slot.link = (out << 16) | from;
    nodes[to - 1].type |= 0x80000000; // (marked, to find it after)
    if (!sortNodes(ma)) {
        slot.link = old;
        nodes[to - 1].type &= 0x7fffffff;
        return null;
    }
    for (nodes[0..n], 1..) |*nd, i| {
        if (nd.type & 0x80000000 != 0) {
            nd.type &= 0x7fffffff;
            return @intCast(i);
        }
    }
    return null;
}

/// Drive pin p by a node's output (node 0: none).
pub fn socket(mi: usize, pin: usize, node: u32, out: u32) bool {
    const ma = own(mi) orelse return false;
    if (pin >= sg.NPINS or node > sg.count(ma)) return false;
    if (node != 0 and out >= sg.NOUTS) return false;
    sg.pinsMut(ma)[pin] = if (node == 0) 0 else (out << 16) | node;
    return true;
}

/// The node gone, the later ones one down, links and pins to it unplugged.
pub fn delete(mi: usize, node: u32) bool {
    const ma = own(mi) orelse return false;
    const n = sg.count(ma);
    if (node == 0 or node > n) return false;
    const nodes = sg.nodesMut(ma);
    std.mem.copyForwards(sg.Node, nodes[node - 1 .. n - 1], nodes[node..n]);
    const fl = ma.graph[NFLAGS..][0..sg.MAX_NODES];
    std.mem.copyForwards(u8, fl[node - 1 .. n - 1], fl[node..n]);
    fl[n - 1] = 0;
    nodes[n - 1] = std.mem.zeroes(sg.Node);
    setCount(ma, n - 1);
    for (nodes[0 .. n - 1]) |*nd| {
        for (&nd.in) |*l| {
            const lo = l.link & 0xffff;
            if (lo == node) {
                l.link = 0; // fed by it: its constant again
            } else if (lo > node) l.link -= 1;
        }
    }
    for (sg.pinsMut(ma)[0..sg.NPINS]) |*p| {
        const lo = p.* & 0xffff;
        if (lo == node) {
            p.* = 0;
        } else if (lo > node) p.* -= 1;
    }
    return true;
}

pub fn clear(mi: usize) void {
    const ma = own(mi) orelse return;
    ma.graph = @splat(0);
}

/// Place a node in the node editor (0: the output).
pub fn place(mi: usize, node: u32, x: i32, y0: i32) bool {
    const ma = own(mi) orelse return false;
    if (node > sg.count(ma)) return false;
    var y = y0;
    if (@as(i16, @truncate(x)) == 0 and @as(i16, @truncate(y)) == 0) y = 1; // ((0, 0) means not placed)
    const pos: [2]i16 = .{ @truncate(x), @truncate(y) };
    if (node == 0) {
        std.mem.writeInt(i16, ma.graph[OUTPOS..][0..2], pos[0], .little);
        std.mem.writeInt(i16, ma.graph[OUTPOS + 2 ..][0..2], pos[1], .little);
    } else sg.nodesMut(ma)[node - 1].pos = pos;
    return true;
}

fn nodeAt(mi: usize, t: u32, x: i32, y: i32) u32 {
    const k = add(mi, t) orelse return 0;
    _ = place(mi, k, x, y);
    return k;
}

// --- material functions (matfunc.s) ------------------------------------------------------

pub const MakeFn = union(enum) { made: usize, need, fail, loop };

/// Up to 3 different links (node | output << 16): the index, null when full.
fn keyOf(ks: *[3]u32, n: *u32, l: u32) ?u32 {
    for (ks[0..n.*], 0..) |k, i| {
        if (k == l) return @intCast(i);
    }
    if (n.* >= 3) return null;
    ks[n.*] = l;
    n.* += 1;
    return n.* - 1;
}

fn selBit(sel: u64, x: u32) bool {
    return sel & (@as(u64, 1) << @intCast(x & 63)) != 0; // (bt: modulo 64)
}

/// material.make_function: the nodes of `sel` (bit n: node n) move into a new
/// function "<name>_fn"; links from outside come through Function Inputs, what
/// was used outside (and pins) leaves through the Function Output, one Material
/// Function node takes their place. `nm`: the name as typed (made from it).
/// The original checks room for the new nodes only as it adds them, leaving a
/// half-made function and no undo step when a graph is full; this checks first
/// and changes nothing.
pub fn makeFunction(mi: usize, nm: []const u8, sel0: u64) MakeFn {
    const ma0 = material.get(mi) orelse return .fail;
    const n = sg.count(ma0);
    const mask: u64 = if (n + 1 >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n + 1)) - 1;
    const sel = sel0 & mask & ~@as(u64, 1);
    if (sel == 0) return .need;
    // what crosses: inputs from outside, outputs used outside (and pins)
    var ins: [3]u32 = @splat(0);
    var nin: u32 = 0;
    var outs: [3]u32 = @splat(0);
    var nout: u32 = 0;
    const nodes0 = sg.nodesOf(ma0);
    for (0..n) |i| {
        const moved = selBit(sel, @intCast(i + 1));
        for (nodes0[i].in) |l| {
            const lo = l.link & 0xffff;
            if (lo == 0 or selBit(sel, lo) == moved) continue;
            if (moved) {
                _ = keyOf(&ins, &nin, l.link) orelse return .fail;
            } else _ = keyOf(&outs, &nout, l.link) orelse return .fail;
        }
    }
    for (sg.pinsOf(ma0)[0..sg.NPINS]) |p| {
        const lo = p & 0xffff;
        if (lo == 0 or !selBit(sel, lo)) continue;
        _ = keyOf(&outs, &nout, p) orelse return .fail;
    }
    // room: the function's nodes, the call, a valid type each, a material
    const nsel: u32 = @popCount(sel);
    if (nin + nsel + @intFromBool(nout > 0) > sg.MAX_NODES or n >= sg.MAX_NODES or material.count >= material.MAX) return .fail;
    for (0..n) |i| {
        if (selBit(sel, @intCast(i + 1)) and (nodes0[i].type == 0 or nodes0[i].type > type_names.len)) return .fail;
    }
    // (as it was: put back when the nodes left would make a loop)
    const keep_count = material.count;
    const keep = material.list[mi];
    // the function: <material>_fn
    var nb: [64]u8 = undefined;
    const base = nm[0..@min(nm.len, 27)];
    const fname = std.fmt.bufPrint(&nb, "{s}_fn", .{base}) catch return .fail;
    const f = material.new(fname) orelse return .fail;
    material.list[f].func = 1;
    var map: [sg.MAX_NODES + 1]u32 = @splat(0);
    var in_node: [3]u32 = @splat(0);
    for (0..nin) |k| { // Function Inputs first (In k)
        in_node[k] = add(f, sg.T_FNIN).?;
        sg.nodesMut(&material.list[f])[in_node[k] - 1].p[0] = @floatFromInt(k);
    }
    for (0..n) |i| { // the moved nodes, in order
        if (!selBit(sel, @intCast(i + 1))) continue;
        const k = add(f, nodes0[i].type).?;
        map[i + 1] = k;
        const nd = &sg.nodesMut(&material.list[f])[k - 1];
        nd.* = nodes0[i]; // the node as it was
        for (&nd.in) |*l| { // its links: inside, renumbered; from outside, its In
            const lo = l.link & 0xffff;
            if (lo == 0) continue;
            if (selBit(sel, lo)) {
                l.link = (l.link & 0xffff0000) | (if (lo <= sg.MAX_NODES) map[lo] else 0);
            } else {
                var to: u32 = 0;
                for (ins[0..3], 0..) |x, q| {
                    if (x == l.link) {
                        to = in_node[q];
                        break;
                    }
                }
                l.link = to;
            }
        }
    }
    if (nout > 0) { // the Function Output, last
        const o = add(f, sg.T_FNOUT).?;
        const nd = &sg.nodesMut(&material.list[f])[o - 1];
        for (outs[0..nout], 0..) |l, c| {
            const lo = l & 0xffff;
            nd.in[c].link = (l & 0xffff0000) | (if (lo <= sg.MAX_NODES) map[lo] else 0);
        }
    }
    // the call, in the material: inputs from what fed the moved nodes
    const call = add(mi, sg.T_FNCALL).?;
    const ma = &material.list[mi];
    const nodes = sg.nodesMut(ma);
    nodes[call - 1].p[0] = @floatFromInt(f + 1);
    for (ins[0..nin], 0..) |l, c| nodes[call - 1].in[c].link = l;
    const redirect = struct {
        fn r(l: u32, s: u64, o: []const u32, c: u32) u32 {
            const lo = l & 0xffff;
            if (lo == 0 or !selBit(s, lo)) return l;
            for (o, 0..) |x, k| {
                if (x == l) return (@as(u32, @intCast(k)) << 16) | c;
            }
            return l;
        }
    }.r;
    for (nodes[0..sg.count(ma)], 1..) |*nd, i| { // what used them: the call's Out k
        if (i == call or selBit(sel, @intCast(i))) continue;
        for (&nd.in) |*l| l.link = redirect(l.link, sel, outs[0..nout], call);
    }
    for (sg.pinsMut(ma)[0..sg.NPINS]) |*p| p.* = redirect(p.*, sel, outs[0..nout], call);
    // the call where the nodes were, the function's inputs at their left, its output at their right
    var sx: i32 = 0;
    var sy: i32 = 0;
    var cnt: i32 = 0;
    var left: i32 = 0x7fffffff;
    var right: i32 = -0x7fffffff;
    for (0..n) |i| {
        if (!selBit(sel, @intCast(i + 1))) continue;
        const x: i32 = nodes[i].pos[0];
        sx += x;
        left = @min(left, x);
        right = @max(right, x);
        sy += nodes[i].pos[1];
        cnt += 1;
    }
    if (cnt > 0) {
        const ax = @divTrunc(sx, cnt);
        const ay = @divTrunc(sy, cnt);
        nodes[call - 1].pos = .{ @truncate(ax), @truncate(ay) };
        for (0..nin) |k| _ = place(f, @intCast(k + 1), left - 220, @as(i32, @intCast(k)) * 110 + ay);
        if (nout > 0) _ = place(f, sg.count(&material.list[f]), right + 240, ay);
    }
    // the moved nodes out (the highest first: the others keep numbers), in order again
    var s = sel;
    while (s != 0) {
        const b: u32 = 63 - @as(u32, @clz(s));
        s &= ~(@as(u64, 1) << @intCast(b));
        _ = delete(mi, b);
    }
    if (!sortNodes(&material.list[mi])) {
        // the call feeds a node that feeds it: the original keeps the graph out
        // of order, saves it, and its own check clears it when the file is read
        // back (the material's graph lost). Nothing changed here instead.
        material.list[mi] = keep;
        material.count = keep_count;
        material.version +%= 1;
        return .loop;
    }
    material.version +%= 1;
    return .{ .made = f };
}

// --- instances (matinst.s) -------------------------------------------------------------

var synced: u32 = 0xffffffff;

/// The instances up to date, before a frame, a render, a probe or a save: each
/// takes its parent's values and graph, its overridden parameters kept.
pub fn syncCheck() void {
    if (material.version == synced) return;
    var any = false;
    for (material.list[0..material.count]) |*ma| {
        if (ma.parent != 0) any = true;
    }
    if (any) syncAll();
    synced = material.version;
}

fn syncAll() void {
    sg.sync_gen +%= 1; // (instances' graphs change: their folded constants go)
    for (0..8) |_| { // (chains)
        for (material.list[0..material.count], 0..) |*ma, i| {
            if (ma.parent == 0 or ma.parent - 1 == i or ma.parent - 1 >= material.count) continue;
            syncOne(i, ma.parent - 1);
        }
    }
}

fn syncOne(i: usize, p: usize) void {
    const inst = &material.list[i];
    const par = &material.list[p];
    const old = inst.graph;
    const oldn = @min(std.mem.readInt(u32, old[0..4], .little), sg.MAX_NODES);
    const dst: [*]u8 = @ptrCast(inst);
    const src: [*]const u8 = @ptrCast(par);
    @memcpy(dst[32..108], src[32..108]); // its values (to the parent)
    inst.graph = par.graph;
    const old_nodes: *const [sg.MAX_NODES]sg.Node = @ptrCast(@alignCast(&old[160 - material.FILE_PART]));
    const n = sg.count(inst);
    for (sg.nodesMut(inst)[0..n], 0..) |*nd, k| {
        inst.graph[NFLAGS + k] &= ~OVR;
        if (!isParam(nd.type)) continue;
        var b1: [24]u8 = undefined;
        const nm = paramName(nd, &b1);
        for (0..oldn) |q| {
            if (old[NFLAGS + q] & OVR == 0) continue;
            const on = &old_nodes[q];
            if (on.type != nd.type) continue;
            var b2: [24]u8 = undefined;
            if (!std.mem.eql(u8, paramName(on, &b2), nm)) continue;
            nd.p = on.p;
            inst.graph[NFLAGS + k] |= OVR;
            break;
        }
    }
}

/// A new instance of a material: its index.
pub fn instanceNew(parent: usize, name: []const u8) ?usize {
    if (parent >= material.count) return null;
    const i = material.new(name) orelse return null;
    material.list[i].parent = @intCast(parent + 1);
    syncOne(i, parent);
    material.version +%= 1;
    return i;
}

/// The parameter node of that name (1..) or 0.
pub fn paramNode(ma: *const Material, nm: []const u8) u32 {
    for (sg.nodesOf(ma)[0..sg.count(ma)], 1..) |*nd, i| {
        if (!isParam(nd.type)) continue;
        var b: [24]u8 = undefined;
        if (std.mem.eql(u8, paramName(nd, &b), nm)) return @intCast(i);
    }
    return 0;
}

/// A parameter's animation channel code (matinst.s pn_hash): 0x10000 | 15 bits of FNV-1a.
fn paramHash(nm: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (nm) |c| {
        h ^= c;
        h *%= 0x01000193;
    }
    return ((h ^ (h >> 15)) & 0x7fff) | 0x10000;
}

/// The code of the parameter of that name, null: it has none.
pub fn paramCode(ma: *const Material, nm: []const u8) ?u32 {
    return if (paramNode(ma, nm) != 0) paramHash(nm) else null;
}

/// A parameter's value by its code (mat_pparam_get / _set: set an instance's: overridden).
pub fn paramByCode(ma: *Material, code: u32, comp: u32, v: f32, set: bool) ?f32 {
    for (sg.nodesMut(ma)[0..sg.count(ma)], 0..) |*nd, i| {
        if (!isParam(nd.type)) continue;
        var b: [24]u8 = undefined;
        if (paramHash(paramName(nd, &b)) != code) continue;
        if (set) {
            nd.p[comp] = v;
            if (ma.parent != 0) ma.graph[NFLAGS + i] |= OVR;
        }
        return nd.p[comp];
    }
    return null;
}

/// Set a parameter's values (an instance's: overridden from now on).
pub fn setParam(mi: usize, node: u32, v: []const f32) void {
    const ma = own(mi) orelse return;
    if (node == 0 or node > sg.count(ma)) return;
    const nd = &sg.nodesMut(ma)[node - 1];
    for (v[0..@min(v.len, 4)], 0..) |x, k| nd.p[k] = x;
    if (ma.parent != 0) ma.graph[NFLAGS + node - 1] |= OVR;
}

pub fn resetParam(mi: usize, node: u32) void {
    const ma = own(mi) orelse return;
    if (node == 0 or node > sg.count(ma)) return;
    ma.graph[NFLAGS + node - 1] &= ~OVR;
}

pub fn overridden(ma: *const Material, node: u32) bool {
    return ma.graph[NFLAGS + node - 1] & OVR != 0;
}

// --- the procedural presets (matlib.s) ---------------------------------------------------

fn vals(mi: usize, node: u32, v: []const f32) void {
    for (v, 0..) |x, k| val(mi, node, @intCast(k + 4), x);
}

/// A ramp between two colours feeding the base colour: its node.
fn two(mi: usize, c0: [3]f32, c1: [3]f32) u32 {
    const r = nodeAt(mi, 6, 240, 40);
    _ = setSlot(mi, r, 2, &c0);
    _ = setSlot(mi, r, 3, &c1);
    _ = socket(mi, sg.PIN_BASE, r, 0);
    return r;
}

/// A pattern node into a ramp to the base colour: the pattern's node.
fn pattern(mi: usize, t: u32, v: []const f32, c0: [3]f32, c1: [3]f32) u32 {
    const k = nodeAt(mi, t, 20, 40);
    vals(mi, k, v);
    const r = two(mi, c0, c1);
    _ = link(mi, k, r, 1, 0);
    return k;
}

/// Its value bumps the normal (strength 0.4).
fn bumpIt(mi: usize, k: u32) void {
    const b = nodeAt(mi, 8, 240, 260);
    vals(mi, b, &.{ 0.4, 0.01 });
    _ = link(mi, k, b, 1, 0);
    _ = socket(mi, sg.PIN_NORMAL, b, 0);
}

/// Preset `nm`'s graph, on a material whose graph is empty.
pub fn buildPreset(mi: usize, nm: []const u8) void {
    if (std.mem.eql(u8, nm, "wood")) {
        const k = nodeAt(mi, 33, 20, 40); // rings: a wave (distorted) -> ramp
        vals(mi, k, &.{ 6, 2, 1, 0 });
        const r = two(mi, .{ 0.30, 0.16, 0.07 }, .{ 0.55, 0.34, 0.17 });
        _ = link(mi, k, r, 1, 0);
    } else if (std.mem.eql(u8, nm, "marble")) {
        _ = pattern(mi, 2, &.{ 3, 6, 0.6 }, .{ 0.96, 0.95, 0.93 }, .{ 0.55, 0.55, 0.58 });
    } else if (std.mem.eql(u8, nm, "concrete")) {
        bumpIt(mi, pattern(mi, 2, &.{ 18, 4, 0.7 }, .{ 0.42, 0.42, 0.41 }, .{ 0.62, 0.62, 0.60 }));
    } else if (std.mem.eql(u8, nm, "fabric")) {
        _ = pattern(mi, 3, &.{60}, .{ 0.16, 0.25, 0.48 }, .{ 0.24, 0.35, 0.62 });
    } else if (std.mem.eql(u8, nm, "leather")) {
        const k = nodeAt(mi, 25, 20, 40); // pores: voronoi -> a bump
        vals(mi, k, &.{ 40, 1 });
        bumpIt(mi, k);
    }
}

// --- texture sets ----------------------------------------------------------------------

pub const K_BASE = 0;
pub const K_NORMAL = 1;
pub const K_ROUGH = 2;
pub const K_GLOSS = 3;
pub const K_METAL = 4;
pub const K_AO = 5;
pub const K_HEIGHT = 6;
pub const K_EMIT = 7;
pub const K_ALPHA = 8;
pub const K_ORM = 9;
pub const NKINDS = 10;

/// Its texture sample (image, sampler: colour / data / normal), fed the UVs.
fn tex(mi: usize, found: *const [NKINDS]u32, kind: usize, y: i32, tc: u32) u32 {
    const k = nodeAt(mi, 1, 260, y);
    if (k == 0) return 0;
    val(mi, k, 4, @floatFromInt(found[kind]));
    val(mi, k, 6, if (kind == K_BASE or kind == K_EMIT) 0 else if (kind == K_NORMAL) 2 else 1);
    _ = link(mi, tc, k, 1, 0);
    return k;
}

/// A material's graph from maps: image + 1 per kind (0: none). no_ao: the
/// packed map's red is not occlusion.
pub fn buildMaps(mi: usize, found: *const [NKINDS]u32, dx: bool, no_ao: bool) void {
    const tc = nodeAt(mi, 10, 20, 40);
    for (0..NKINDS) |kind| {
        if (found[kind] == 0) continue;
        // (gloss beside roughness, height beside a normal map: not needed)
        if (kind == K_GLOSS and found[K_ROUGH] != 0) continue;
        if (kind == K_HEIGHT and found[K_NORMAL] != 0) continue;
        const y: i32 = @as(i32, @intCast(kind)) * 150 + 20;
        const k = tex(mi, found, kind, y, tc);
        if (k == 0) continue;
        switch (kind) {
            K_BASE => _ = socket(mi, sg.PIN_BASE, k, 0),
            K_EMIT => {
                _ = socket(mi, sg.PIN_EMIT, k, 0);
                material.list[mi].strength = 1;
            },
            K_ROUGH => _ = socket(mi, sg.PIN_ROUGH, k, 1), // data: their red
            K_METAL => _ = socket(mi, sg.PIN_METAL, k, 1),
            K_AO => _ = socket(mi, sg.PIN_AO, k, 1),
            K_ALPHA => {
                _ = socket(mi, sg.PIN_MASK, k, 1);
                material.list[mi].blend = 1; // (masked)
            },
            K_ORM => {
                // occlusion, roughness, metallic: R G B (unless there are maps of their own)
                if (found[K_AO] == 0 and !no_ao) _ = socket(mi, sg.PIN_AO, k, 1);
                if (found[K_ROUGH] == 0) _ = socket(mi, sg.PIN_ROUGH, k, 2);
                if (found[K_METAL] == 0) _ = socket(mi, sg.PIN_METAL, k, 3);
            },
            K_GLOSS => {
                const o = nodeAt(mi, 7, 430, y); // gloss: one minus it
                val(mi, o, 4, 18);
                _ = link(mi, k, o, 1, 1);
                _ = socket(mi, sg.PIN_ROUGH, o, 0);
            },
            K_NORMAL => {
                const o = nodeAt(mi, 9, 430, y);
                val(mi, o, 5, if (dx) 1 else 0);
                _ = link(mi, k, o, 1, 0);
                _ = socket(mi, sg.PIN_NORMAL, o, 0);
            },
            K_HEIGHT => {
                const o = nodeAt(mi, 8, 430, y); // a bump (no normal map)
                val(mi, o, 5, 0.02);
                _ = link(mi, k, o, 1, 1);
                _ = socket(mi, sg.PIN_NORMAL, o, 0);
            },
            else => {},
        }
    }
    _ = place(mi, 0, 640, 40);
}

// --- glTF's texture slots (matlib.s ml_gltf): glTF, USD and .blend imports ---------------

/// A material's maps as glTF has them (image + 1, 0: none) with their factors
/// (matlib.s's GT).
pub const Gt = struct {
    base: u32 = 0,
    mr: u32 = 0,
    nrm: u32 = 0,
    occ: u32 = 0,
    emi: u32 = 0,
    nscale: f32 = 1,
    tile: [2]f32 = .{ 1, 1 }, // u, v
    off: [2]f32 = .{ 0, 0 }, // u, v
    basef: [4]f32 = .{ 1, 1, 1, 1 }, // r g b a
    metalf: f32 = 1,
    roughf: f32 = 1,
    emif: [3]f32 = .{ 1, 1, 1 },
    alpha: u32 = 0, // 0 opaque, 1 mask, 2 blend
};

/// ucomiss x, 1.0 then jne: equal, or unordered (NaN) as equal
fn isOne(x: f32) bool {
    return !(x < 1.0 or x > 1.0);
}

const GltfCtx = struct { mi: usize, tc: u32, y: i32 };

/// mg_sample: a Texture Sample node of an image (+ 1) and sampler, fed the UVs
fn gSample(c: *GltfCtx, img: u32, sampler: u32) u32 {
    const k = nodeAt(c.mi, 1, 240, c.y);
    c.y += 150;
    val(c.mi, k, 4, @floatFromInt(img));
    val(c.mi, k, 6, @floatFromInt(sampler));
    _ = link(c.mi, c.tc, k, 1, 0);
    return k;
}

/// mg_tint: the node giving the colour (a Mix, multiply, when the factor is
/// not white)
fn gTint(c: *GltfCtx, k: u32, f: [3]f32) u32 {
    if (isOne(f[0]) and isOne(f[1]) and isOne(f[2])) return k;
    const x = nodeAt(c.mi, 5, 430, c.y - 150);
    val(c.mi, x, 4, 2);
    val(c.mi, x, 1, 1);
    _ = setSlot(c.mi, x, 3, &f); // colour 2: the factor
    _ = link(c.mi, k, x, 2, 0);
    return x;
}

/// mg_scale: (node, output): the same, or a Math multiply when the factor is
/// not 1
fn gScale(c: *GltfCtx, k: u32, out: u32, f: f32) [2]u32 {
    if (isOne(f)) return .{ k, out };
    const x = nodeAt(c.mi, 7, 430, c.y - 150 + @as(i32, @intCast(out)));
    val(c.mi, x, 4, 2); // multiply (op 2), B: the factor
    val(c.mi, x, 2, f);
    _ = link(c.mi, k, x, 1, out);
    return .{ x, 0 };
}

/// ml_gltf: a material's graph from glTF's maps: base colour (x its factor;
/// alpha to the mask or opacity), metallic-roughness (B, G; x their factors),
/// occlusion (R; the same sample when it is the same image), normal (a Normal
/// Map node, its scale), emission (x its factor), all through one Texture
/// Coordinate node carrying KHR_texture_transform's scale and offset.
pub fn gltf(mi: usize, g: *const Gt) void {
    defer _ = place(mi, 0, 820, 40); // the output at the right
    var c = GltfCtx{ .mi = mi, .tc = nodeAt(mi, 10, 20, 40), .y = 20 };
    if (c.tc == 0) return;
    const to = [4]f32{ g.tile[0], g.tile[1], g.off[0], g.off[1] };
    for (to, 0..) |x, k| val(mi, c.tc, @intCast(4 + k), x);
    var mr: u32 = 0; // the metallic-roughness sample
    if (g.base != 0) {
        const s = gSample(&c, g.base, 0);
        _ = socket(mi, sg.PIN_BASE, gTint(&c, s, g.basef[0..3].*), 0);
        if (g.alpha == 1) {
            _ = socket(mi, sg.PIN_MASK, s, 4); // its alpha: the mask or opacity
        } else if (g.alpha == 2) _ = socket(mi, sg.PIN_ALPHA, s, 4);
    }
    if (g.mr != 0) {
        mr = gSample(&c, g.mr, 1);
        const a = gScale(&c, mr, 3, g.metalf);
        _ = socket(mi, sg.PIN_METAL, a[0], a[1]);
        const b = gScale(&c, mr, 2, g.roughf);
        _ = socket(mi, sg.PIN_ROUGH, b[0], b[1]);
    }
    if (g.occ != 0) {
        const s = if (g.occ == g.mr) mr else gSample(&c, g.occ, 1);
        _ = socket(mi, sg.PIN_AO, s, 1);
    }
    if (g.nrm != 0) {
        const s = gSample(&c, g.nrm, 2);
        const n = nodeAt(mi, 9, 430, c.y - 150);
        val(mi, n, 4, g.nscale);
        _ = link(mi, s, n, 1, 0);
        _ = socket(mi, sg.PIN_NORMAL, n, 0);
    }
    if (g.emi != 0) {
        const s = gSample(&c, g.emi, 0);
        _ = socket(mi, sg.PIN_EMIT, gTint(&c, s, g.emif), 0);
        // (a strength: 1 unless it has one)
        const ma = material.get(mi) orelse return;
        if (!(0 < ma.strength) and !std.math.isNan(ma.strength)) {
            ma.strength = 1;
            material.version +%= 1;
        }
    }
}

// the keywords, longest first where one holds another, normals before the
// packed maps ("normal" holds "orm")
const Key = struct { k: u8, s: []const u8 };
const keys = [_]Key{
    .{ .k = K_NORMAL, .s = "normal" }, .{ .k = K_NORMAL, .s = "nrm" },    .{ .k = K_NORMAL, .s = "nml" },          .{ .k = K_NORMAL, .s = "nor" },
    .{ .k = K_ORM, .s = "orm" },       .{ .k = K_ORM, .s = "arm" },       .{ .k = K_BASE, .s = "basecolor" },      .{ .k = K_BASE, .s = "base_color" },
    .{ .k = K_BASE, .s = "albedo" },   .{ .k = K_BASE, .s = "diffuse" },  .{ .k = K_BASE, .s = "color" },          .{ .k = K_BASE, .s = "colour" },
    .{ .k = K_BASE, .s = "diff" },     .{ .k = K_BASE, .s = "col" },      .{ .k = K_ROUGH, .s = "roughness" },     .{ .k = K_ROUGH, .s = "rough" },
    .{ .k = K_ROUGH, .s = "rgh" },     .{ .k = K_GLOSS, .s = "gloss" },   .{ .k = K_METAL, .s = "metalness" },     .{ .k = K_METAL, .s = "metallic" },
    .{ .k = K_METAL, .s = "metal" },   .{ .k = K_METAL, .s = "met" },     .{ .k = K_AO, .s = "ambientocclusion" }, .{ .k = K_AO, .s = "occlusion" },
    .{ .k = K_AO, .s = "occ" },        .{ .k = K_AO, .s = "ao" },         .{ .k = K_HEIGHT, .s = "displacement" }, .{ .k = K_HEIGHT, .s = "height" },
    .{ .k = K_HEIGHT, .s = "disp" },   .{ .k = K_HEIGHT, .s = "bump" },   .{ .k = K_EMIT, .s = "emissive" },       .{ .k = K_EMIT, .s = "emission" },
    .{ .k = K_EMIT, .s = "emit" },     .{ .k = K_ALPHA, .s = "opacity" }, .{ .k = K_ALPHA, .s = "alpha" },         .{ .k = K_ALPHA, .s = "mask" },
};

/// The kind a lower-case word names, or null.
pub fn kindOf(word: []const u8) ?u8 {
    for (keys) |k| {
        if (std.mem.indexOf(u8, word, k.s) != null) return k.k;
    }
    return null;
}

/// dx, gl, ogl, directx, opengl and resolutions (digits, "k" at the end allowed).
fn isMod(w: []const u8) bool {
    for ([_][]const u8{ "dx", "gl", "ogl", "directx", "opengl" }) |x| {
        if (std.mem.eql(u8, w, x)) return true;
    }
    var i: usize = 0;
    while (i < w.len and w[i] >= '0' and w[i] <= '9') i += 1;
    if (i == 0) return false;
    if (i < w.len and w[i] == 'k') i += 1;
    return i == w.len;
}

fn isSep(c: u8) bool {
    return c == '_' or c == '-' or c == ' ';
}

/// A set's prefix from one file name: up to the last separator before the
/// extension, without the words naming a map or how it was made (as in
/// "rock_normal_dx_2k", "rock_albedo_4k").
pub fn prefixOf(file: []const u8) []const u8 {
    const stop = std.mem.indexOfScalar(u8, file, '.') orelse file.len;
    var end: usize = 0;
    for (file[0..@min(stop, 120)], 0..) |c, i| {
        if (isSep(c)) end = i + 1;
    }
    var i = end;
    var cut = end;
    while (i >= 2) {
        // the word before the separator at i - 1
        var s = i - 1;
        while (s > 0 and !isSep(file[s - 1])) s -= 1;
        var low: [64]u8 = undefined;
        const n = @min(i - 1 - s, low.len);
        const w = std.ascii.lowerString(low[0..n], file[s..][0..n]);
        i = s;
        if (kindOf(w) != null) {
            cut = s; // a map: cut here
        } else if (!isMod(w)) break;
    }
    return file[0..cut];
}

/// Seconds at the scene's frame.
pub fn sceneTime() f32 {
    const f = @import("frange.zig").r.fps;
    return (@import("anim.zig").frame - 1) / f;
}

const t_ = std.testing;

test "texture set names: prefix, kinds" {
    try t_.expectEqualStrings("rock_", prefixOf("rock_normal_dx_2k.png"));
    try t_.expectEqualStrings("rock_", prefixOf("rock_albedo_4k.jpg"));
    try t_.expectEqualStrings("Bricks012_2K-", prefixOf("Bricks012_2K-Color.png"));
    try t_.expectEqualStrings("", prefixOf("rock.png"));
    try t_.expectEqual(@as(?u8, K_NORMAL), kindOf("normal_dx"));
    try t_.expectEqual(@as(?u8, K_ORM), kindOf("orm"));
    try t_.expectEqual(@as(?u8, K_BASE), kindOf("basecolor"));
    try t_.expectEqual(@as(?u8, null), kindOf("rock"));
}

fn testReset() void {
    material.reset();
    _ = material.new("m").?;
}

test "nodes: links sort, loops refused, delete unplugs" {
    testReset();
    const a = add(0, 16).?; // constant
    const b = add(0, 7).?; // math
    const c = add(0, 17).?; // color
    try t_.expectEqual(@as(u32, 3), c);
    // c -> b: c must move before b
    const fed = link(0, c, b, 1, 0).?;
    try t_.expectEqual(@as(u32, 3), fed);
    const nodes = sg.nodesOf(&material.list[0]);
    try t_.expectEqual(@as(u32, 7), nodes[2].type);
    try t_.expectEqual(@as(u32, 2), nodes[2].in[0].link);
    // a link that would loop changes nothing
    const before = material.list[0].graph;
    try t_.expect(link(0, fed, 2, 1, 0) == null);
    try t_.expectEqualSlices(u8, &before, &material.list[0].graph);
    try t_.expect(socket(0, sg.PIN_BASE, 3, 0));
    try t_.expect(delete(0, 2));
    try t_.expectEqual(@as(u32, 2), sg.count(&material.list[0]));
    try t_.expectEqual(@as(u32, 0), nodes[1].in[0].link);
    try t_.expectEqual(@as(u32, 2), sg.pinsOf(&material.list[0])[sg.PIN_BASE]);
    _ = a;
}

test "instances: parent's graph, overrides stay, reset goes back" {
    testReset();
    const k = add(0, 37).?;
    try t_.expect(socket(0, sg.PIN_ROUGH, k, 0));
    var b: [24]u8 = undefined;
    try t_.expectEqualStrings("Param 1", paramName(&sg.nodesOf(&material.list[0])[0], &b));
    setParamName(&sg.nodesMut(&material.list[0])[0], "Wear");
    const i = instanceNew(0, "inst").?;
    try t_.expectEqual(@as(u32, 1), paramNode(&material.list[i], "Wear"));
    setParam(i, 1, &.{0.9});
    setParam(0, 1, &.{0.25});
    material.list[0].metallic = 0.75;
    material.version +%= 1;
    syncCheck();
    try t_.expectEqual(@as(f32, 0.9), sg.nodesOf(&material.list[i])[0].p[0]);
    try t_.expectEqual(@as(f32, 0.75), material.list[i].metallic);
    resetParam(i, 1);
    syncCheck();
    try t_.expectEqual(@as(f32, 0.25), sg.nodesOf(&material.list[i])[0].p[0]);
}
