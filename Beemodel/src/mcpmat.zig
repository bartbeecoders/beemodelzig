// MCP tools for materials (the original's mcpmat.s), and the material JSON the
// scene summary shares (mcp.s graph_json, copilot.s ty_json):
//
//   material_node_types: the material nodes' catalogue.
//   material_graph {name}: a material's values and graph as JSON (the form
//     scene_summary uses, with each node's place and parameter name).
//   material_graph_set {name, graph}: replaces a material's graph (made when
//     there is none by that name) from that same JSON: nodes in order (links may
//     point anywhere: the graph sorts itself; a loop is refused), their values,
//     inputs (constants or links), places, parameter names and the Material
//     Output's sockets.
const std = @import("std");
const json = @import("json.zig");
const mcp = @import("mcp.zig");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const gops = @import("graphops.zig");
const shnodes = @import("shnodes.zig");
const images = @import("images.zig");
const app = @import("app.zig");

const MAX_NODES = 48;

const tools_json =
    ",{\"name\":\"material_node_types\",\"description\":\"The material node catalogue (the node editor's): every type with its inputs (slots 1-3, kinds, defaults), values (slots 4-7, kinds, choices, defaults) and outputs, and how material_graph_set and BeeScript use them.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}" ++
    ",{\"name\":\"material_graph\",\"description\":\"A material's node graph as JSON: nodes (type, values, inputs as constants or links {link: node, output}, pos, parameter name) and the Material Output's sockets.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}" ++
    ",{\"name\":\"material_graph_set\",\"description\":\"Replace a material's node graph (the material is made when missing) from the JSON material_graph returns: graph = {nodes: [...], sockets: {...}}. Nodes are numbered from 1 in order. One undo step.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"graph\":{\"type\":\"object\"}},\"required\":[\"name\",\"graph\"]}}";

pub const provider = mcp.Provider{ .tools_json = tools_json, .tier = tier, .dispatch = dispatch };

/// mm_tier: 0 read, 1 edit, null when not one of these.
fn tier(tool: []const u8) ?u32 {
    if (eq(tool, "material_node_types") or eq(tool, "material_graph")) return 0;
    if (eq(tool, "material_graph_set")) return 1;
    return null;
}

/// mm_dispatch: true when it was one of these (its text written).
fn dispatch(tool: []const u8) bool {
    const w = &mcp.txt;
    if (eq(tool, "material_node_types")) {
        typesJson(w);
    } else if (eq(tool, "material_graph")) {
        get(w);
    } else if (eq(tool, "material_graph_set")) {
        set(w);
    } else return false;
    return true;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- graph_json (mcp.s) ------------------------------------------------------------

fn isParamType(t: u32) bool {
    return t >= 37 and t <= 39;
}

fn gjOutput(w: *json.W, k: u32) void {
    if (k == 0) return;
    w.raw(",\"output\":");
    w.num(@floatFromInt(k));
}

/// graph_json: ,"texture":..,"nodes":[..],"sockets":{..} (nothing for a
/// material without nodes).
pub fn graphJson(w: *json.W, ma: *const material.Material) void {
    var n = ma.nodes();
    if (n == 0) return;
    if (n > MAX_NODES) n = MAX_NODES;
    const nodes = sg.nodesOf(ma);
    const pins = sg.pinsOf(ma);
    // "texture": the image behind base
    const pb: u32 = pins[0] & 0xffff;
    if (pb != 0 and pb <= n and nodes[pb - 1].type == 1) {
        const im = cvtt(nodes[pb - 1].p[0]) -% 1;
        if (im >= 0 and im < images.count) {
            w.char(',');
            w.key("texture");
            w.q(images.nameOf(@intCast(im)));
        }
    }
    w.raw(",\"nodes\":[");
    for (nodes[0..n], 0..) |*nd, k| {
        if (k > 0) w.char(',');
        w.raw("{\"type\":");
        if (nd.type -% 1 < gops.type_names.len) w.q(gops.type_names[nd.type - 1]) else w.raw("null");
        w.raw(",\"values\":[");
        for (nd.p, 0..) |v, c| {
            if (c > 0) w.char(',');
            w.num(v);
        }
        w.raw("],\"inputs\":[");
        // (those its type has: type 0 and unknown ones none)
        const meta: ?*const shnodes.Meta = if (nd.type >= 1 and nd.type <= gops.type_names.len) shnodes.of(nd.type) else null;
        if (meta) |me| {
            for (0..3) |c| {
                if (me.inputs[c] == null) break;
                if (c > 0) w.char(',');
                const l = nd.in[c].link;
                if (l != 0) {
                    w.raw("{\"link\":");
                    w.num(@floatFromInt(l & 0xffff));
                    gjOutput(w, (l >> 16) & 0xff);
                    w.char('}');
                } else {
                    w.char('[');
                    w.num(nd.in[c].v[0]);
                    w.char(',');
                    w.num(nd.in[c].v[1]);
                    w.char(',');
                    w.num(nd.in[c].v[2]);
                    w.char(']');
                }
            }
        }
        w.raw("],\"pos\":[");
        w.int(nd.pos[0]);
        w.char(',');
        w.int(nd.pos[1]);
        w.char(']');
        if (isParamType(nd.type)) {
            var b: [24]u8 = undefined;
            w.raw(",\"name\":");
            w.q(gops.paramName(nd, &b));
        }
        w.char('}');
    }
    w.raw("],\"sockets\":{");
    var written = false;
    for (pins[0..sg.NPINS], 0..) |p, k| {
        if (p & 0xffff == 0) continue;
        if (written) w.char(',');
        written = true;
        w.key(gops.socket_names[k]);
        const o = (p >> 16) & 0xff;
        if (o != 0) w.raw("{\"node\":");
        w.num(@floatFromInt(p & 0xffff));
        if (o != 0) {
            gjOutput(w, o);
            w.char('}');
        }
    }
    w.char('}');
}

/// cvttss2si: out of range or NaN gives the minimum.
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

// ---- the catalogue (copilot.s ty_json, material tables) -------------------------------

const in_kinds = [_][]const u8{ "geometry", "value", "vector", "colour" };
const mpar_kinds = [_][]const u8{ "number", "choice", "image", "whole number", "function" };
const mtypes_a = "{\"material_nodes\":[";
const mtypes_b = "],\"how\":\"material_graph_set {name, graph} replaces a material's graph: graph.nodes is a list of {type, values: [p0..p3], inputs: three of [x,y,z] constants or {link: node, output: k}, pos: [x,y], name (parameters)}; nodes are numbered from 1 in that order, links may point anywhere (the graph sorts itself); graph.sockets maps a Material Output pin (base, metallic, specular, roughness, emission, opacity, normal, ao, clearcoat, coat_roughness, transmission, ior, mask) to a node number or {node, output}. material_graph {name} reads it back the same way. In BeeScript: node(m, type, values...), link(m, from, to, input, output), nodeset, socket. Value kinds: number, choice (an index into the choices), image (the image number + 1), whole number, function (the material + 1).\"}";

/// mn_types_json: every material node type (its inputs, values, the first
/// three outputs), as the co-pilot's node_types writes the geometry nodes.
pub fn typesJson(w: *json.W) void {
    w.raw(mtypes_a);
    for (&shnodes.metas, 0..) |*me, ti| {
        if (ti > 0) w.char(',');
        w.raw("{\"type\":");
        w.q(gops.type_names[ti]);
        w.raw(",\"title\":");
        w.q(me.title);
        const d = &gops.defaults[ti];
        w.raw(",\"inputs\":[");
        var nw: u32 = 0;
        for (0..3) |c| {
            const nm = me.inputs[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"slot\":");
            w.int(@intCast(c + 1));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            w.q(in_kinds[me.in_kinds[c] & 3]);
            w.raw(",\"default\":[");
            w.float(d[4 + c * 3]);
            w.char(',');
            w.float(d[5 + c * 3]);
            w.char(',');
            w.float(d[6 + c * 3]);
            w.raw("]}");
            nw += 1;
        }
        w.raw("],\"values\":[");
        nw = 0;
        for (0..4) |c| {
            const nm = me.values[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"slot\":");
            w.int(@intCast(c + 4));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            const k: u8 = if (me.val_kinds[c] <= 4) me.val_kinds[c] else 0;
            w.q(mpar_kinds[k]);
            w.raw(",\"default\":");
            w.float(d[c]);
            if (k == 1 and me.choices.len > 0) {
                w.raw(",\"choices\":[");
                for (me.choices, 0..) |ch, j| {
                    if (j > 0) w.char(',');
                    w.q(ch);
                }
                w.char(']');
            }
            w.char('}');
            nw += 1;
        }
        w.raw("],\"outputs\":[");
        nw = 0;
        for (0..3) |c| {
            const nm = me.outputs[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"index\":");
            w.int(@intCast(c));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            w.q(in_kinds[me.out_kinds[c] & 3]);
            w.char('}');
            nw += 1;
        }
        w.raw("]}");
    }
    w.raw(mtypes_b);
}

// ---- material_graph ----------------------------------------------------------------

/// mm_json: {"name":..,["function":true,] graph}
fn matJson(w: *json.W, mi: usize) void {
    gops.syncCheck(); // (an instance: up to date)
    const ma = &material.list[mi];
    w.raw("{\"name\":");
    w.q(ma.nameOf());
    if (ma.func == 1) w.raw(",\"function\":true");
    graphJson(w, ma);
    w.raw("}");
}

fn get(w: *json.W) void {
    var nb: [60]u8 = undefined;
    const name = mcp.argStr("name", &nb) orelse "";
    if (name.len == 0) return mcp.fail("material_graph: give the material's name", "");
    const mi = material.find(name) orelse return mcp.fail("no material named ", name);
    matJson(w, mi);
}

// ---- material_graph_set ------------------------------------------------------------

/// mm_ws: past whitespace.
fn mmWs(t: []const u8, i: usize) usize {
    return json.ws(t, i);
}

fn at(t: []const u8, i: usize) u8 {
    return if (i < t.len) t[i] else 0;
}

/// mm_nums: a number or a list (up to 3) -> how many.
fn nums(t: []const u8, v: usize, out: *[3]f32) u32 {
    const i = mmWs(t, v);
    if (at(t, i) != '[') {
        const r = json.num(t, i);
        if (!r.ok) return 0;
        out[0] = r.v;
        return 1;
    }
    var n: u32 = 0;
    var e = json.first(t, i);
    while (e) |el| {
        if (n >= 3) break;
        out[n] = json.num(t, el).v;
        n += 1;
        e = json.next(t, el);
    }
    return n;
}

var save: [material.REC - material.FILE_PART]u8 = undefined;

fn set(w: *json.W) void {
    const t = mcp.msg;
    var nb: [60]u8 = undefined;
    const name = mcp.argStr("name", &nb) orelse "";
    if (name.len == 0) return mcp.fail("material_graph: give the material's name", "");
    const mi = material.find(name) orelse (material.new(name) orelse return mcp.fail("material_graph: give the material's name", ""));
    const bad = "material_graph_set: graph must be an object with a nodes list";
    const g0 = mcp.argVal("graph") orelse return mcp.fail(bad, "");
    const g = mmWs(t, g0);
    if (at(t, g) != '{') return mcp.fail(bad, "");
    const nl = json.find(t, g, "nodes") orelse return mcp.fail(bad, "");
    if (at(t, mmWs(t, nl)) != '[') return mcp.fail(bad, "");
    var list: [MAX_NODES]usize = undefined;
    var n: u32 = 0;
    var e = json.first(t, mmWs(t, nl));
    while (e) |el| {
        if (n >= MAX_NODES) return mcp.fail("material_graph_set: at most 48 nodes", "");
        list[n] = el;
        n += 1;
        e = json.next(t, el);
    }
    const ma = &material.list[mi];
    save = ma.graph; // (the graph as it was: a failure puts it back)
    var ok = false;
    defer if (!ok) {
        ma.graph = save;
        material.version +%= 1;
    };
    gops.clear(mi);
    // each node, in order: its type, values, place, parameter name
    var word: [60]u8 = undefined;
    for (list[0..n], 0..) |nd, k| {
        const tv = json.find(t, nd, "type") orelse return mcp.fail("unknown node type: ", "");
        // (not a string: the original took the word read before, a stale buffer)
        const tn = json.str(t, tv, &word) orelse "";
        const ty = gops.typeIndex(tn) orelse return mcp.fail("unknown node type: ", tn);
        const num = gops.add(mi, ty) orelse return mcp.fail("material_graph_set: at most 48 nodes", "");
        if (json.find(t, nd, "values")) |vv| {
            if (at(t, mmWs(t, vv)) == '[') {
                var c: u32 = 0;
                var ve = json.first(t, mmWs(t, vv));
                while (ve) |x| {
                    if (c >= 4) break;
                    const r = json.num(t, x);
                    if (r.ok) _ = gops.setSlot(mi, num, c + 4, &.{r.v});
                    c += 1;
                    ve = json.next(t, x);
                }
            }
        }
        if (json.find(t, nd, "pos")) |pv| {
            var xy: [3]f32 = undefined;
            if (nums(t, pv, &xy) >= 2) _ = gops.place(mi, num, cvtt(xy[0]), cvtt(xy[1]));
        }
        if (json.find(t, nd, "name")) |sv| {
            var pn: [30]u8 = undefined;
            const s = json.str(t, sv, &pn) orelse "";
            const node = &sg.nodesMut(ma)[k];
            if (s.len > 0 and isParamType(node.type)) gops.setParamName(node, s);
        }
    }
    // then the inputs: constants, links
    for (list[0..n], 0..) |nd, k| {
        const iv = json.find(t, nd, "inputs") orelse continue;
        if (at(t, mmWs(t, iv)) != '[') continue;
        var c: usize = 0;
        var ie = json.first(t, mmWs(t, iv));
        while (ie) |x| : ({
            c += 1;
            ie = json.next(t, x);
        }) {
            if (c >= 3) break;
            const node = &sg.nodesMut(ma)[k];
            const xi = mmWs(t, x);
            if (at(t, xi) != '{') {
                // (two numbers: the third 0; the original took a stale stack slot)
                var v: [3]f32 = .{ 0, 0, 0 };
                const got = nums(t, xi, &v);
                if (got == 0) continue;
                if (got == 1) {
                    v[1] = v[0];
                    v[2] = v[0];
                }
                node.in[c] = .{ .link = 0, .v = v };
                continue;
            }
            const lv = json.find(t, xi, "link") orelse continue;
            const l: u32 = @bitCast(cvtt(json.num(t, lv).v));
            if (l -% 1 >= n) continue;
            var o: u32 = 0;
            if (json.find(t, xi, "output")) |ov| o = @as(u32, @bitCast(cvtt(json.num(t, ov).v))) & 7;
            node.in[c].link = (o << 16) | l;
        }
    }
    // the sockets
    if (json.find(t, g, "sockets")) |sv0| {
        const so = mmWs(t, sv0);
        if (at(t, so) == '{') {
            const pins = sg.pinsMut(ma);
            for (gops.socket_names, 0..) |sn, k| {
                const pv0 = json.find(t, so, sn) orelse continue;
                var pv = mmWs(t, pv0);
                var o: u32 = 0;
                if (at(t, pv) == '{') {
                    if (json.find(t, pv, "output")) |ov| o = @as(u32, @bitCast(cvtt(json.num(t, ov).v))) & 7;
                    pv = json.find(t, pv, "node") orelse continue;
                }
                const r = json.num(t, pv);
                if (!r.ok) continue;
                const l: u32 = @bitCast(cvtt(r.v));
                if (l -% 1 >= n) continue;
                pins[k] = l | (o << 16);
            }
        }
    }
    if (!gops.sortNodes(ma)) return mcp.fail("material_graph_set: the links make a loop (the graph is as it was)", "");
    ok = true;
    material.version +%= 1;
    app.dirty = true;
    matJson(w, mi);
}
