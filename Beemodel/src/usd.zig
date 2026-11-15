//! OpenUSD stages: layers composed into prims, and the import of their meshes
//! (file.import_usd; .usd .usda .usdc), as usd.s does it.
//!
//! Each stage prim keeps its opinions in order, strongest first: nodes of
//! (layer, path in it, and the namespace mapping its reference brought:
//! source root -> stage root). A prim's nodes start as its parent's nodes'
//! children; then each node adds, after the ones there:
//!   variants    the selected variant of each variant set it has (the
//!               selection: the strongest one on the prim), as the node
//!               prim{set=sel} in the same layer
//!   references  and payloads: the referenced layer stack (its file and its
//!               sublayers, each opened once) at the target prim (or that
//!               layer's defaultPrim), mapped onto this prim
//! so arcs inside referenced layers compose too. A field's value is the first
//! node's that has it. Relationship targets go through their node's mapping
//! into stage paths (material bindings name prims of the referencing file).
//! Children are the union of the nodes' primChildren; inactive prims and
//! classes are left out.
//!
//! The import walks the stage: transforms (xformOpOrder: translate, scale,
//! rotateX/Y/Z, rotate in all six orders, orient, transform), Z up turned to
//! Y up, metersPerUnit; meshes (faceVertexCounts / Indices, points,
//! primvars:st as vertex / faceVarying, indexed or not, leftHanded), split
//! into an object for each material bound (GeomSubsets of faces), placed like
//! Blender imports (C W C^-1 split into place, turn and scale; baked when it
//! shears), all in a folder named after the file.
const std = @import("std");
const ul = @import("usdlayer.zig");
const usdc = @import("usdc.zig");
const usda = @import("usda.zig");
const m4 = @import("m4d.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const usdmat = @import("usdmat.zig");
const usdphys = @import("usdphys.zig");
const Layer = ul.Layer;
const Value = ul.Value;
const Str = ul.Str;

const A = std.heap.page_allocator;

pub const list = .{
    .{ "file.import_usd", ops.Impl{ .run = opImportUsd } },
    .{ "file.usd_dump", ops.Impl{ .run = opUsdDump } },
    .{ "file.usd_texture_size", ops.Impl{ .run = opTexSize } },
};

const MAXLAY = 256; // layers a stage opens
const MAXSTK = 32; // layers in a stack
pub const MAXN = 64; // nodes a prim
const MAXPRIM = 200000;
const MAXDEPTH = 64;

/// a node: a layer, a path in it, the mapping its reference brought
pub const Node = struct {
    lay: *Layer,
    path: [*:0]const u8,
    src: Str = null, // source root (null: none) ->
    dst: [*:0]const u8 = "/", //  stage root
};

/// a prim record (by stage path number)
const Prim = struct {
    nodes: ?[*]Node = null,
    nn: u32 = 0,
    kids: ?[*]u32 = null,
    nk: u32 = 0,
    done: bool = false,
};

/// a cached layer: its file, it, its stack (strongest first)
const Lc = struct {
    file: [*:0]const u8,
    lay: *Layer,
    stk: [*]*Layer,
    nstk: u32,
};

/// usd_open: a file's layer (null: usdc.err says why): crate files by their
/// magic, the rest as text
pub fn open(path: []const u8) ?*Layer {
    const d = ul.mapFile(path) orelse {
        usdc.err = usdc.e_open;
        return null;
    };
    const crate = d.len >= 8 and std.mem.readInt(u64, d[0..8], .little) == usdc.MAGIC;
    ul.unmapFile(d);
    return if (crate) usdc.read(path) else usda.read(path);
}

// ---- the stage's state (usd.s's us_*) ---------------------------------------------------

pub var st: ?*Layer = null; // the stage: its paths, its arena
var prims: []Prim = &.{};
var lcs: [MAXLAY]Lc = undefined;
var nlc: u32 = 0;
var depth: u32 = 0;
var sdepth: u32 = 0;
var nprim: u32 = 0;
var nobj: u32 = 0;
var nmesh: u32 = 0;
var nskip: u32 = 0;
var folder: u32 = 0;
var rootlc: u32 = 0;
/// C: the stage to BeeModel (axes, units); C^-1
pub var cm: m4.M = m4.ident;
var ci: m4.M = m4.ident;
/// true: no rigid bodies, no joints (lib.get ... static)
pub var nophys = false;
/// where it lands: added to every place (an online asset at the 3D cursor)
pub var off: [3]f64 = .{ 0, 0, 0 };
var tbuf: [4097]u8 = undefined;
var tbuf2: [4097]u8 = undefined;

fn stA() *Layer {
    return st.?;
}

fn dupSt(s: []const u8) [*:0]const u8 {
    return stA().ar.dup(s) orelse "";
}

fn txt(s: Str) [*:0]const u8 {
    return s orelse ""; // (a crate's path list may name no path: the original crashes on it)
}

// ---- layers and stacks -----------------------------------------------------------------

/// us_load: a file's cache entry (the layer and its stack opened), null when
/// it cannot be read. Each file is opened once.
fn load(file: [*:0]const u8) ?u32 {
    const f = ul.cstr(file);
    for (lcs[0..nlc], 0..) |*e, i| {
        if (ul.eq(e.file, file)) return @intCast(i);
    }
    if (nlc >= MAXLAY) return null;
    const lay = open(f) orelse {
        app.log("  usd: a layer it uses cannot be read: {s}", .{f});
        return null;
    };
    const k = nlc;
    const stk = stA().ar.many(*Layer, MAXSTK) orelse {
        ul.free(lay);
        return null;
    };
    lcs[k] = .{ .file = dupSt(f), .lay = lay, .stk = stk, .nstk = 1 };
    stk[0] = lay; // itself first (sublayers may come back to it: no loop)
    nlc += 1;
    sublayers(k, lay);
    return k;
}

/// the layer's subLayers (each with theirs, strongest first) added to the
/// entry's stack
fn sublayers(k: u32, lay: *Layer) void {
    sdepth += 1;
    defer sdepth -= 1;
    if (sdepth > 16) return;
    const s = ul.specOf(lay, "/") orelse return;
    const v = ul.get(lay, s, "subLayers") orelse return;
    if (v.t != ul.UT_SLIST) return;
    for (v.texts()) |t| {
        const p = resolve(txt(t), lay.file);
        const sub = open(p) orelse continue; // (a sublayer: not cached on its own)
        const e = &lcs[k];
        if (e.nstk >= MAXSTK) {
            ul.free(sub);
            continue;
        }
        e.stk[e.nstk] = sub;
        e.nstk += 1;
        sublayers(k, sub);
    }
}

/// us_resolve: an asset path, absolute as it is, else beside the file it is
/// written in ("./" dropped): in tbuf2
pub fn resolve(asset: [*:0]const u8, base: [*:0]const u8) [:0]const u8 {
    var a = ul.cstr(asset);
    var o: usize = 0;
    if (!(a.len > 0 and a[0] == '/')) {
        const b = ul.cstr(base);
        var keep: usize = 0; // the folder: up to its last '/'
        for (b, 0..) |c, i| {
            if (c == '/') keep = i + 1;
        }
        if (keep <= 3000) {
            @memcpy(tbuf2[0..keep], b[0..keep]);
            o = keep;
            while (a.len >= 2 and a[0] == '.' and a[1] == '/') a = a[2..];
        }
    }
    const n = @min(a.len, 4090 -| o);
    @memcpy(tbuf2[o..][0..n], a[0..n]);
    o += n;
    tbuf2[o] = 0;
    return tbuf2[0..o :0];
}

// ---- text helpers ----------------------------------------------------------------------

/// us_cat: a + sep + b, in the stage's arena (sep '/': left out after "/" or
/// "}" - and not before an empty a; '.', or 0)
fn cat(a: [*:0]const u8, b: [*:0]const u8, sep: u8) [*:0]const u8 {
    var o: usize = 0;
    o = cpy(&tbuf, o, a, 4000);
    if (sep != 0) {
        const skip = sep == '/' and o > 0 and (tbuf[o - 1] == '/' or tbuf[o - 1] == '}');
        if (!skip) {
            tbuf[o] = sep;
            o += 1;
        }
    }
    o = cpy(&tbuf, o, b, 4000);
    tbuf[o] = 0;
    return dupSt(tbuf[0..o]);
}

/// us_cpy: copied to the limit
fn cpy(buf: []u8, at: usize, s: [*:0]const u8, lim: usize) usize {
    var o = at;
    var i: usize = 0;
    while (o < lim and s[i] != 0) : (i += 1) {
        buf[o] = s[i];
        o += 1;
    }
    return o;
}

/// us_prefix: the rest of path after root when root is a whole-element
/// prefix of it ("" when equal), null when not
fn prefix(p: [*:0]const u8, root: [*:0]const u8) ?[*:0]const u8 {
    var i: usize = 0;
    while (root[i] != 0) : (i += 1) {
        if (root[i] != p[i]) return null;
    }
    const c = p[i];
    if (c == 0 or c == '/' or c == '.' or c == '{') return p + i;
    if (i == 1 and root[0] == '/') return p; // (root "/": anything under it)
    return null;
}

/// us_lastname: its last element (after the last '/' or '}')
fn lastName(s: [*:0]const u8) [*:0]const u8 {
    var r = s;
    var i: usize = 0;
    while (s[i] != 0) {
        const c = s[i];
        i += 1;
        if (c == '/' or c == '}') r = s + i;
    }
    return r;
}

fn starts(t: [*:0]const u8, pre: []const u8) ?[*:0]const u8 {
    for (pre, 0..) |c, i| {
        if (t[i] != c) return null;
    }
    return t + pre.len;
}

/// us_word: text is word, alone or followed by ":suffix"
fn word(t: [*:0]const u8, w: []const u8) bool {
    const r = starts(t, w) orelse return false;
    return r[0] == 0 or r[0] == ':';
}

// ---- composition --------------------------------------------------------------------

/// us_prec: a stage path's prim record (grown as needed), null
fn prec(i: u32) ?*Prim {
    if (i >= prims.len) {
        const cap = @as(usize, i) * 2 + 1024;
        const np = A.alloc(Prim, cap) catch return null;
        @memcpy(np[0..prims.len], prims);
        @memset(np[prims.len..], .{});
        if (prims.len > 0) A.free(prims);
        prims = np;
    }
    return &prims[i];
}

/// us_done: it is a composed prim
pub fn done(i: u32) bool {
    return i < prims.len and prims[i].done;
}

/// us_source: its weakest node's layer and path (where it is defined:
/// instances of one definition share it)
pub fn source(i: u32) ?Node {
    const p = prec(i) orelse return null;
    if (p.nn == 0) return null;
    return p.nodes.?[p.nn - 1];
}

/// us_prim_path: its stage path text
pub fn primPath(i: u32) [*:0]const u8 {
    return stA().paths[i].str;
}

fn nspec(n: *const Node) ?u32 {
    return ul.specOf(n.lay, n.path);
}

fn nget(n: *const Node, f: [*:0]const u8) ?*Value {
    const s = nspec(n) orelse return null;
    return ul.get(n.lay, s, f);
}

fn nodesOf(i: u32) []Node {
    const p = prec(i) orelse return &.{};
    const ns = p.nodes orelse return &.{};
    return ns[0..p.nn];
}

/// us_pget: the strongest value of a prim field
pub fn pget(i: u32, f: [*:0]const u8) ?*Value {
    for (nodesOf(i)) |*n| {
        if (nget(n, f)) |v| return v;
    }
    return null;
}

/// us_pany: any of its nodes' lists for that field (a list op: apiSchemas
/// ...) has the text
pub fn pany(i: u32, f: [*:0]const u8, t: []const u8) bool {
    const ns = nodesOf(i);
    var k = ns.len;
    while (k > 0) {
        k -= 1;
        const v = nget(&ns[k], f) orelse continue;
        if (v.t != ul.UT_SLIST) continue;
        for (v.texts()) |x| {
            if (x != null and std.mem.eql(u8, ul.cstr(x.?), t)) return true;
        }
    }
    return false;
}

pub const Got = struct { v: *Value, n: *const Node };

/// us_aget: the strongest value of a property field ("default",
/// "interpolation", "targetPaths" ...), and the node it came from
pub fn aget(i: u32, prop: [*:0]const u8, f: [*:0]const u8) ?Got {
    for (nodesOf(i)) |*n| {
        var o = cpy(&tbuf, 0, n.path, 4000); // node path . property
        tbuf[o] = '.';
        o += 1;
        o = cpy(&tbuf, o, prop, 4000);
        tbuf[o] = 0;
        const s = ul.specOf(n.lay, @ptrCast(&tbuf)) orelse continue;
        if (ul.get(n.lay, s, f)) |v| return .{ .v = v, .n = n };
    }
    return null;
}

pub fn agetv(i: u32, prop: [*:0]const u8) ?*Value {
    const g = aget(i, prop, "default") orelse return null;
    return g.v;
}

/// us_map: a path in a node's layer as a stage path (through its mapping)
pub fn map(n: *const Node, p: [*:0]const u8) [*:0]const u8 {
    const s = n.src orelse return p;
    const rest = prefix(p, s) orelse return p;
    return cat(n.dst, rest, 0);
}

/// us_rel: its first target as a stage path, null
pub fn rel(i: u32, r: [*:0]const u8) ?[*:0]const u8 {
    const g = aget(i, r, "targetPaths") orelse return null;
    if (g.v.t != ul.UT_SLIST or g.v.n == 0) return null;
    const t = g.v.texts();
    if (t.len == 0) return null;
    const first = t[0] orelse return null;
    return map(g.n, first);
}

/// us_addnode: the count after (unchanged when full, or when the layer has
/// no spec there, or the same node is there already)
fn addNode(ns: [*]Node, n: u32, lay: *Layer, p: [*:0]const u8, src: Str, dst: [*:0]const u8) u32 {
    if (n >= MAXN) return n;
    if (ul.specOf(lay, p) == null) return n;
    for (ns[0..n]) |*x| {
        if (x.lay == lay and ul.eq(x.path, p)) return n;
    }
    ns[n] = .{ .lay = lay, .path = p, .src = src, .dst = dst };
    return n + 1;
}

/// us_stacknodes: a node for each layer of the entry's stack
fn stackNodes(ns: [*]Node, n0: u32, k: u32, p: [*:0]const u8, src: Str, dst: [*:0]const u8) u32 {
    var n = n0;
    const e = &lcs[k];
    for (e.stk[0..e.nstk]) |lay| n = addNode(ns, n, lay, p, src, dst);
    return n;
}

/// us_lc_of: the cache entry whose stack has the layer
fn lcOf(lay: *Layer) ?u32 {
    for (lcs[0..nlc], 0..) |*e, i| {
        for (e.stk[0..e.nstk]) |l| {
            if (l == lay) return @intCast(i);
        }
    }
    return null;
}

/// us_vselect: the strongest selection for a variant set (null: none)
fn vselect(set: [*:0]const u8, ns: [*]Node, n: u32) ?[*:0]const u8 {
    for (ns[0..n]) |*x| {
        const v = nget(x, "variantSelection") orelse continue;
        if (v.t != ul.UT_VSEL) continue;
        const t = v.texts();
        var k: usize = 0;
        while (k < v.n and k * 2 + 1 < t.len) : (k += 1) {
            const key = t[k * 2] orelse continue;
            if (!ul.eq(key, set)) continue;
            const sel = t[k * 2 + 1] orelse continue;
            if (sel[0] != 0) return sel;
        }
    }
    return null;
}

/// us_defprim: "/" + its defaultPrim (else its first root prim), null: none
fn defPrim(lay: *Layer) ?[*:0]const u8 {
    const s = ul.specOf(lay, "/") orelse return null;
    var name: [*:0]const u8 = undefined;
    if (ul.get(lay, s, "defaultPrim")) |v| {
        if (v.t == ul.UT_STR) {
            name = v.str();
            return defName(name);
        }
    }
    const v = ul.get(lay, s, "primChildren") orelse return null;
    if (v.t != ul.UT_SLIST or v.n == 0) return null;
    const t = v.texts();
    if (t.len == 0) return null;
    return defName(txt(t[0]));
}

fn defName(n0: [*:0]const u8) [*:0]const u8 {
    var n = n0;
    if (n[0] == '/') n += 1; // (written with its slash already)
    return cat("/", n, '/');
}

/// us_skippable: the prim is inactive or its strongest specifier is a class
/// (the first node's opinion only, as the original asks)
fn skippable(ns: [*]Node) bool {
    if (nget(&ns[0], "active")) |v| {
        if (v.t == ul.UT_INT and v.int() == 0) return true;
    }
    if (nget(&ns[0], "specifier")) |v| {
        if (v.t == ul.UT_INT and v.int() == 2) return true;
    }
    return false;
}

/// us_compose: the prim made: its arcs expanded, its children composed
/// (depth-first)
fn compose(pi: u32, ns: [*]Node, n0: u32) void {
    depth += 1;
    defer depth -= 1;
    if (depth > MAXDEPTH) return;
    if (nprim >= MAXPRIM) return;
    nprim += 1;
    {
        const p = prec(pi) orelse return;
        p.nodes = ns;
        p.done = true;
    }
    var n = n0;
    // ---- arcs, node by node
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const nd = ns[k];
        if (nget(&nd, "variantSetNames")) |sets| {
            if (sets.t == ul.UT_SLIST) {
                for (sets.texts()) |set0| {
                    const set = txt(set0);
                    const sel = vselect(set, ns, n) orelse continue;
                    var o = cpy(&tbuf2, 0, nd.path, 3900); // path{set=sel}
                    tbuf2[o] = '{';
                    o += 1;
                    o = cpy(&tbuf2, o, set, 3900);
                    tbuf2[o] = '=';
                    o += 1;
                    o = cpy(&tbuf2, o, sel, 3900);
                    tbuf2[o] = '}';
                    tbuf2[o + 1] = 0;
                    n = addNode(ns, n, nd.lay, dupSt(tbuf2[0 .. o + 1]), nd.src, nd.dst);
                }
            }
        }
        for ([_][*:0]const u8{ "references", "payload" }) |fname| { // references, then payloads
            const v = nget(&nd, fname) orelse continue;
            if (v.t != ul.UT_RLIST) continue;
            const t = v.texts();
            var r: usize = 0;
            while (r < v.n and r * 2 + 1 < t.len) : (r += 1) {
                const asset = t[r * 2];
                var tp: Str = t[r * 2 + 1]; // prim path (none: the default prim)
                var e: u32 = undefined;
                if (asset == null or asset.?[0] == 0) { // internal: this layer's stack
                    e = lcOf(nd.lay) orelse continue;
                } else {
                    const fp = resolve(asset.?, nd.lay.file);
                    e = load(fp.ptr) orelse continue;
                }
                if (tp == null or tp.?[0] == 0) tp = defPrim(lcs[e].lay) orelse continue;
                n = stackNodes(ns, n, e, tp.?, tp, primPath(pi)); // mapped onto this prim
            }
        }
    }
    prec(pi).?.nn = n;
    // ---- children: the union of the nodes' primChildren
    var room: u64 = 0;
    for (ns[0..n]) |*nd| {
        const v = nget(nd, "primChildren") orelse continue;
        if (v.t == ul.UT_SLIST) room += v.n;
    }
    const kids = stA().ar.many(u32, @intCast(room + 2)) orelse return;
    var nk: u32 = 0;
    for (ns[0..n]) |*nd| {
        const v = nget(nd, "primChildren") orelse continue;
        if (v.t != ul.UT_SLIST) continue;
        for (v.texts()) |name| {
            const sp = cat(primPath(pi), txt(name), '/');
            if (ul.find(stA(), sp) != null) continue; // (met already: in the list)
            const c = ul.path(stA(), sp, @intCast(pi), ul.UK_PRIM) orelse continue;
            if (nk >= room) continue;
            kids[nk] = c;
            nk += 1;
        }
    }
    {
        const p = prec(pi).?;
        p.kids = kids;
        p.nk = nk;
    }
    for (kids[0..nk]) |c| { // each child: its nodes, composed
        const name = lastName(primPath(c));
        const cn = stA().ar.many(Node, MAXN) orelse return;
        var m: u32 = 0;
        for (ns[0..n]) |*nd| m = addNode(cn, m, nd.lay, cat(nd.path, name, '/'), nd.src, nd.dst);
        if (m == 0) continue;
        if (skippable(cn)) continue; // inactive, or a class: left out
        compose(c, cn, m);
    }
}

/// us_stage: the stage composed (st ...), false: not read. free lets it all go.
pub fn stage(file: []const u8) bool {
    nlc = 0;
    depth = 0;
    nprim = 0;
    prims = &.{};
    st = ul.new() orelse return false;
    _ = ul.path(stA(), "/", -1, ul.UK_ROOT); // stage path 0: "/"
    var fb: [4097]u8 = undefined;
    const n = @min(file.len, 4096);
    @memcpy(fb[0..n], file[0..n]);
    fb[n] = 0;
    rootlc = load(@ptrCast(&fb)) orelse {
        free();
        return false;
    };
    const ns = stA().ar.many(Node, MAXN) orelse {
        free();
        return false;
    };
    const k = stackNodes(ns, 0, rootlc, "/", null, "/");
    compose(0, ns, k);
    return true;
}

/// us_free: every layer the stage opened, the stage
pub fn free() void {
    for (lcs[0..nlc]) |*e| {
        for (e.stk[0..e.nstk]) |l| ul.free(l);
    }
    nlc = 0;
    if (prims.len > 0) A.free(prims);
    prims = &.{};
    ul.free(st);
    st = null;
}

// ---- transforms ---------------------------------------------------------------------

const deg: f64 = 0.017453292519943295;
const orders = [6]*const [3]u8{ "XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX" }; // m4_euler's modes 1 .. 6

/// us_xform: the prim's own transform, and whether it resets the transform
/// stack (the parent's left out). Row-major, column vectors.
fn xform(pi: u32, out: *m4.M) bool {
    var reset = false;
    out.* = m4.ident;
    const ord = agetv(pi, "xformOpOrder") orelse return false;
    if (ord.t != ul.UT_SLIST) return false;
    for (ord.texts()) |op0| {
        var op = txt(op0);
        if (ul.eq(op, "!resetXformStack!")) {
            reset = true; // the parent's left out; ops before it too
            out.* = m4.ident;
            continue;
        }
        var inv = false; // inverted? (translate, scale: pivots)
        if (starts(op, "!invert!")) |r| {
            op = r;
            inv = true;
        }
        const v = agetv(pi, op) orelse continue;
        const kind = starts(op, "xformOp:") orelse continue; // its kind: after "xformOp:"
        // (a one-axis rotation's value is a lone number: the original asks every
        // op for a vector and so leaves rotateX / Y / Z out - a bug, not copied)
        if (v.t != ul.UT_VEC and !(v.t == ul.UT_DBL and oneAxis(kind))) continue;
        const m = opMat(kind, v, inv) orelse continue;
        out.* = m4.mul(out.*, m); // M = M op
    }
    return reset;
}

/// rotateX / rotateY / rotateZ, maybe ":suffix"
fn oneAxis(kind: [*:0]const u8) bool {
    const r = starts(kind, "rotate") orelse return false;
    return r[0] >= 'X' and r[0] <= 'Z' and (r[1] == 0 or r[1] == ':');
}

/// us_opmat: an op's matrix ("translate", "rotateXYZ" ..., maybe ":suffix";
/// inverted: translate and scale only), null not known
fn opMat(kind: [*:0]const u8, v: *const Value, inv: bool) ?m4.M {
    var m = m4.ident;
    const d = v.vec();
    if (word(kind, "translate")) {
        if (v.n < 3) return null;
        for (0..3) |c| m[c * 4 + 3] = if (inv) 0.0 - d[c] else d[c];
        return m;
    }
    if (word(kind, "scale")) {
        if (v.n < 3) return null;
        for (0..3) |c| m[c * 5] = if (inv) 1.0 / d[c] else d[c];
        return m;
    }
    if (inv) return null; // (others inverted: not known)
    if (word(kind, "orient")) {
        if (v.n < 4) return null;
        return m4.quat(.{ @floatCast(d[3]), @floatCast(d[0]), @floatCast(d[1]), @floatCast(d[2]) }); // x y z w -> w x y z (floats)
    }
    if (word(kind, "transform")) {
        if (v.n < 16) return null;
        for (0..16) |i| m[(i & 3) * 4 + (i >> 2)] = d[i]; // USD's rows are vectors: ours is its transpose
        return m;
    }
    const r = starts(kind, "rotate") orelse return null; // rotateX / Y / Z, rotateXYZ ...
    if (r[0] == 0) return null;
    if (r[1] == 0 or r[1] == ':') { // one axis: rotateX
        const ax = r[0] -% 'X';
        if (ax > 2) return null;
        if (v.t == ul.UT_DBL) return m4.axisRot(ax, v.dbl() * deg);
        if (v.n < 1) return null;
        return m4.axisRot(ax, d[0] * deg);
    }
    if (v.n < 3) return null; // three: the first named turns first
    if (r[2] == 0) return null;
    for (orders, 1..) |o, mode| {
        if (r[0] != o[0] or r[1] != o[1] or r[2] != o[2]) continue;
        // the angles are X Y Z whatever the order (UsdGeomXformOp): the
        // original took them in the order's letters - a bug, not copied (its
        // rotateXYZ, the only order where the two agree, is unchanged)
        var ang: [3]f32 = undefined;
        for (0..3) |c| ang[c] = @floatCast(d[c] * deg);
        return m4.euler(ang, @intCast(mode));
    }
    return null;
}

// ---- the import -----------------------------------------------------------------------

/// usd_import: 0 ok, 1 unreadable, 2 nothing imported
pub fn import(path: []const u8) u32 {
    nobj = 0;
    nmesh = 0;
    nskip = 0;
    usdmat.reset();
    usdphys.reset();
    if (!stage(path)) {
        app.log("{s}{s}", .{ usdc.err, path });
        return 1;
    }
    axes(lcs[rootlc].lay); // C: axes and units from the root layer
    var nb: [32]u8 = undefined;
    folder = @import("folders.zig").make(baseName(path, &nb), 0); // a folder named after the file
    const id = m4.ident;
    if (prec(0)) |p| { // every prim under "/"
        const kids = p.kids;
        const nk = p.nk;
        if (kids) |ks| for (ks[0..nk]) |c| walk(c, &id, null);
    }
    if (!nophys) usdphys.finish(); // bodies and joints (the stage still there)
    scr.free();
    free();
    app.log("  usd: {d} objects from {d} meshes, {d} skipped", .{ nobj, nmesh, nskip });
    return if (nobj == 0) 2 else 0;
}

/// us_basename: its file name without the extension, at most 31 characters
fn baseName(p: []const u8, out: *[32]u8) []const u8 {
    const b = p[if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| s + 1 else 0..];
    var n: usize = 0;
    while (n < b.len and b[n] != 0 and b[n] != '.' and n < 31) : (n += 1) out[n] = b[n];
    return out[0..n];
}

/// us_axes: cm / ci: Z up turned to Y up, metersPerUnit
fn axes(lay: *Layer) void {
    cm = m4.ident;
    var units: f64 = 1.0;
    if (ul.specOf(lay, "/")) |s| {
        if (ul.get(lay, s, "upAxis")) |v| {
            if (v.t == ul.UT_STR and ul.eq(v.str(), "Z")) cm = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1 };
        }
        if (ul.get(lay, s, "metersPerUnit")) |v| {
            if (v.t == ul.UT_DBL and v.dbl() > 0) units = v.dbl();
        }
    }
    for (0..16) |i| ci[i] = cm[(i & 3) * 4 + (i >> 2)]; // C^-1: the turn's transpose / units
    for (0..12) |i| {
        if (i & 3 == 3) continue;
        cm[i] *= units;
        ci[i] /= units;
    }
}

fn textIs(v: ?*Value, t: []const u8) bool {
    const x = v orelse return false;
    return x.t == ul.UT_STR and std.mem.eql(u8, ul.cstr(x.str()), t);
}

/// us_walk: the prim's meshes made, then its children's
fn walk(pi: u32, parent: *const m4.M, above: ?[*:0]const u8) void {
    const p = prec(pi) orelse return;
    if (!p.done) return;
    const pur = agetv(pi, "purpose"); // guides, proxies, invisible: out
    if (textIs(pur, "guide") or textIs(pur, "proxy")) return;
    if (textIs(agetv(pi, "visibility"), "invisible")) return;
    var w: m4.M = undefined; // its world matrix
    if (!xform(pi, &w)) w = m4.mul(parent.*, w); // (reset: its own alone)
    const body = usdphys.enter(pi, &w); // a body or a joint
    var mat = above;
    if (rel(pi, "material:binding")) |b| mat = b; // a material bound here
    if (textIs(pget(pi, "typeName"), "Mesh")) mesh(pi, &w, mat);
    var k: u32 = 0;
    while (true) : (k += 1) { // its children
        const q = prec(pi) orelse break;
        if (k >= q.nk) break;
        walk(q.kids.?[k], &w, mat);
    }
    usdphys.leave(body);
}

// ---- meshes -------------------------------------------------------------------------

/// the mesh being made (usd.s's um_*)
const Mk = struct {
    pts: []align(1) const f32 = &.{},
    np: u64 = 0,
    cnt: []align(1) const i32 = &.{},
    nf: u64 = 0,
    idx: []align(1) const i32 = &.{},
    ni: u64 = 0,
    uv: []align(1) const f32 = &.{},
    nuv: u64 = 0,
    uvi: ?[]align(1) const i32 = null,
    nuvi: u64 = 0,
    uvmode: u32 = 0, // 0 none, 1 per point, 2 per corner
    left: bool = false,
    slot: []u8 = &.{}, // per face: its material slot
    mats: [64]?[*:0]const u8 = @splat(null), // slot -> material stage path
    nmat: u32 = 0,
    foff: []u32 = &.{}, // per face: its first index
    map: []u32 = &.{}, // point -> group vertex + 1
    m: m4.M = m4.ident, // placed matrix
    mv: m4.M = m4.ident, // the vertex matrix
    placed: bool = false,
};
var mk: Mk = .{};

/// Buffers the meshes of an import reuse (grown as needed, let go after it).
const Scratch = struct {
    foff: []u32 = &.{},
    slot: []u8 = &.{},
    map: []u32 = &.{},
    verts: [][3]f32 = &.{},
    poff: []u32 = &.{},
    loops: []u32 = &.{},
    uv: [][2]f32 = &.{},

    fn grow(comptime T: type, b: *[]T, n: usize) ?[]T {
        if (b.len < n) {
            if (b.len > 0) A.free(b.*);
            b.* = &.{};
            b.* = A.alloc(T, @max(n, 4096 / @sizeOf(T))) catch return null;
        }
        return b.*[0..n];
    }
    fn free(s: *Scratch) void {
        inline for (.{ "foff", "slot", "map", "verts", "poff", "loops", "uv" }) |f| {
            if (@field(s, f).len > 0) A.free(@field(s, f));
            @field(s, f) = &.{};
        }
    }
};
var scr: Scratch = .{};

/// us_mesh: its objects: one for each material its faces use
fn mesh(pi: u32, w: *const m4.M, above: ?[*:0]const u8) void {
    nmesh += 1;
    mk = .{};
    blk: {
        const pv = agetv(pi, "points") orelse break :blk;
        if (pv.t != ul.UT_FARR or pv.x != 3) break :blk;
        mk.pts = pv.farr();
        mk.np = pv.n;
        const cv = agetv(pi, "faceVertexCounts") orelse break :blk;
        if (cv.t != ul.UT_IARR) break :blk;
        mk.cnt = cv.iarr();
        mk.nf = cv.n;
        const iv = agetv(pi, "faceVertexIndices") orelse break :blk;
        if (iv.t != ul.UT_IARR) break :blk;
        mk.idx = iv.iarr();
        mk.ni = iv.n;
        if (mk.nf == 0 or mk.np == 0) break :blk;
        mk.left = textIs(agetv(pi, "orientation"), "leftHanded"); // winding
        mk.foff = Scratch.grow(u32, &scr.foff, @intCast(mk.nf)) orelse break :blk; // per face: first index, slot
        mk.slot = Scratch.grow(u8, &scr.slot, @intCast(mk.nf)) orelse break :blk;
        mk.map = Scratch.grow(u32, &scr.map, @intCast(mk.np)) orelse break :blk;
        if (!check()) { // counts and indices in range
            app.log("  usd: a mesh with bad indices left out: {s}", .{ul.cstr(primPath(pi))});
            break :blk;
        }
        uvs(pi);
        // slots: the mesh's own binding, else the one above; subsets
        mk.nmat = 1;
        mk.mats[0] = rel(pi, "material:binding") orelse above;
        subsets(pi);
        matrices(w); // placing: C W C^-1, split; baked when it shears
        var s: u32 = 0;
        while (s < mk.nmat) : (s += 1) { // an object for each slot used
            const mi = group(s) orelse continue;
            var nmb: [32]u8 = undefined;
            const nm = objName(lastName(primPath(pi)), &nmb);
            const oi = @import("bs_cad.zig").objNew(.mesh, nm, mi, 0xb4b8c0) orelse {
                freeMeshSlot(mi);
                continue;
            };
            nobj += 1;
            const o = &scene.objects[oi];
            if (mk.placed) {
                const pl = m4.place(mk.m);
                o.loc = pl.loc;
                o.scl = pl.scl;
                o.setRadians(pl.rot);
            }
            if (folder != 0) @import("folders.zig").setObject(o, folder);
            if (mk.mats[s]) |mp| { // its material
                if (usdmat.get(mp)) |k| scene.objects[oi].mat = @intCast(k + 1);
            }
            usdphys.object(pi, oi); // its physics
        }
        return;
    }
    nskip += 1;
}

fn freeMeshSlot(mi: u16) void {
    if (scene.meshes[mi]) |*me| scene.freeMesh(me);
    scene.freeMeshSlot(mi);
}

/// us_objname: the name without a leading "sm_" and a trailing
/// "_mesh_<digits>" (SimReady's), at most 31 characters
fn objName(s0: [*:0]const u8, out: *[32]u8) []const u8 {
    var s = s0;
    if (s[0] == 's' and s[1] == 'm' and s[2] == '_' and s[3] != 0) s += 3;
    var n: usize = 0;
    while (n < 31 and s[n] != 0) : (n += 1) out[n] = s[n];
    var d = n; // "_mesh_" then only digits at the end?
    while (d > 0 and out[d - 1] >= '0' and out[d - 1] <= '9') d -= 1;
    if (d != n and d >= 7 and std.mem.eql(u8, out[d - 6 .. d], "_mesh_")) return out[0 .. d - 6];
    return out[0..n];
}

/// um_check: the counts add up to the indices and each index names a point;
/// foff filled
fn check() bool {
    var first: u64 = 0;
    for (0..@intCast(mk.nf)) |f| {
        mk.foff[f] = @truncate(first);
        const c = mk.cnt[f];
        if (c < 0) return false;
        first += @intCast(c);
        if (first > mk.ni) return false;
    }
    for (mk.idx[0..@intCast(first)]) |x| {
        if (@as(u32, @bitCast(x)) >= mk.np) return false;
    }
    return true;
}

const uv_names = [_][*:0]const u8{ "primvars:st", "primvars:st0", "primvars:UVMap", "primvars:uv", "primvars:map1" };

/// um_uvs: its texture coordinates: the first of primvars:st ... that is a
/// float2 array, per point (vertex / varying) or per corner (faceVarying),
/// with or without its :indices
fn uvs(pi: u32) void {
    mk.uvmode = 0;
    mk.uvi = null;
    for (uv_names) |nm| {
        const v = agetv(pi, nm) orelse continue;
        if (v.t != ul.UT_FARR or v.x != 2) continue;
        mk.uv = v.farr();
        mk.nuv = v.n;
        var mode: u32 = 1; // (vertex / varying: per point)
        if (aget(pi, nm, "interpolation")) |g| {
            if (textIs(g.v, "faceVarying")) mode = 2;
        }
        var b: [4100]u8 = undefined; // its indices: name + ":indices"
        var o = cpy(&b, 0, nm, 4000);
        o = cpy(&b, o, ":indices", 4000);
        b[o] = 0;
        if (agetv(pi, @ptrCast(&b))) |iv| {
            if (iv.t == ul.UT_IARR) {
                mk.uvi = iv.iarr();
                mk.nuvi = iv.n;
            }
        }
        mk.uvmode = mode;
        return;
    }
}

/// um_uvat: a corner's UV (two floats as their 64 bits), 0 when it has none
/// (a UV of exactly 0, 0 counts as none, as in the original)
fn uvAt(corner: u64) u64 {
    if (mk.uvmode == 0) return 0;
    var k: u64 = corner;
    if (mk.uvmode != 2) k = @as(u32, @bitCast(mk.idx[@intCast(corner)])); // per point: its point
    if (mk.uvi) |ix| { // through the indices
        if (k >= mk.nuvi) return 0;
        k = @as(u32, @bitCast(ix[@intCast(k)]));
    }
    if (k >= mk.nuv) return 0;
    const u: u32 = @bitCast(mk.uv[@intCast(k * 2)]);
    const v: u32 = @bitCast(mk.uv[@intCast(k * 2 + 1)]);
    return @as(u64, v) << 32 | u;
}

/// um_subsets: each GeomSubset child (faces, materialBind) with a material
/// bound: its faces get a slot of their own
fn subsets(pi: u32) void {
    @memset(mk.slot, 0); // all: slot 0
    var k: u32 = 0;
    while (true) : (k += 1) {
        const p = prec(pi) orelse return;
        if (k >= p.nk) return;
        const c = p.kids.?[k];
        if (!textIs(pget(c, "typeName"), "GeomSubset")) continue;
        if (agetv(c, "elementType")) |v| { // faces? (elementType face)
            if (!textIs(v, "face")) continue;
        }
        if (agetv(c, "familyName")) |v| { // (another family: not materials)
            if (!textIs(v, "materialBind")) continue;
        }
        const m = rel(c, "material:binding") orelse continue;
        var s: u32 = 0; // its slot: the same material's, or new
        while (s < mk.nmat) : (s += 1) {
            if (mk.mats[s]) |x| {
                if (ul.eq(x, m)) break;
            }
        }
        if (s >= mk.nmat) {
            if (s >= 64) continue;
            mk.mats[s] = m;
            mk.nmat += 1;
        }
        const iv = agetv(c, "indices") orelse continue; // its faces
        if (iv.t != ul.UT_IARR) continue;
        for (iv.iarr()[0..@intCast(iv.n)]) |f| {
            const fu: u32 = @bitCast(f);
            if (fu < mk.nf) mk.slot[fu] = @intCast(s);
        }
    }
}

/// um_matrices: m: C W C^-1 (placed by it when it splits without shear), mv:
/// the matrix for the vertices (C, or C W when baked)
fn matrices(w: *const m4.M) void {
    mk.m = m4.mul(m4.mul(cm, w.*), ci);
    mk.placed = m4.split(mk.m).ortho;
    if (mk.placed) {
        mk.mv = cm;
        for (0..3) |c| mk.m[c * 4 + 3] += off[c]; // (placed: moved by off)
    } else {
        mk.mv = m4.mul(cm, w.*);
        for (0..3) |c| mk.mv[c * 4 + 3] += off[c]; // (baked: its vertices moved)
    }
}

/// um_xpt: a point through mv
fn xpt(p: u32) [3]f32 {
    const x: f64 = mk.pts[p * 3];
    const y: f64 = mk.pts[p * 3 + 1];
    const z: f64 = mk.pts[p * 3 + 2];
    var o: [3]f32 = undefined;
    for (0..3) |r| {
        var s = mk.mv[r * 4] * x;
        s += mk.mv[r * 4 + 1] * y;
        s += mk.mv[r * 4 + 2] * z;
        s += mk.mv[r * 4 + 3];
        o[r] = @floatCast(s);
    }
    return o;
}

/// um_group: a mesh of the faces in that slot (with their UVs when every
/// corner has one), null when none
fn group(slot: u32) ?u16 {
    @memset(mk.map, 0);
    var faces: u32 = 0;
    var corners: u32 = 0;
    for (0..@intCast(mk.nf)) |f| {
        if (mk.slot[f] != slot) continue;
        const c: u32 = @bitCast(mk.cnt[f]);
        if (c < 3) continue;
        faces += 1;
        corners +%= c;
    }
    if (faces == 0) return null;
    const vs = Scratch.grow([3]f32, &scr.verts, @min(@as(usize, corners), @as(usize, @intCast(mk.np)))) orelse return null;
    const po = Scratch.grow(u32, &scr.poff, @as(usize, faces) + 1) orelse return null;
    const lo = Scratch.grow(u32, &scr.loops, corners) orelse return null;
    const uvl = Scratch.grow([2]f32, &scr.uv, if (mk.uvmode != 0) corners else 0) orelse return null;
    var nv: usize = 0;
    var np: usize = 0;
    var nl: usize = 0;
    po[0] = 0;
    var every = true; // every corner had a UV
    for (0..@intCast(mk.nf)) |f| {
        if (mk.slot[f] != slot) continue;
        const n: u32 = @bitCast(mk.cnt[f]); // corners
        if (n < 3 or n > 1024) continue;
        const first: u64 = mk.foff[f];
        for (0..n) |j| {
            const c: u64 = first + (if (mk.left) n - j - 1 else j); // (left handed: the other way round)
            const p: u32 = @bitCast(mk.idx[@intCast(c)]); // its point
            if (mk.map[p] == 0) {
                vs[nv] = xpt(p);
                nv += 1;
                mk.map[p] = @intCast(nv);
            }
            lo[nl + j] = mk.map[p] - 1;
            if (mk.uvmode != 0) { // its UVs, in corner order
                const u = uvAt(c);
                if (u == 0) every = false;
                uvl[nl + j] = .{ @bitCast(@as(u32, @truncate(u))), @bitCast(@as(u32, @truncate(u >> 32))) };
            }
        }
        nl += n;
        np += 1;
        po[np] = @intCast(nl);
    }
    if (np == 0) return null;
    const mi = scene.addMesh(vs[0..nv], po[0 .. np + 1], lo[0..nl]) orelse return null;
    if (mk.uvmode != 0 and every) { // (a corner without: no UVs at all)
        const al = @import("alloc.zig").A;
        if (scene.meshes[mi]) |*me| me.uv = al.dupe([2]f32, uvl[0..nl]) catch &.{};
    }
    return mi;
}

// ---- the operators --------------------------------------------------------------------

/// im_next_word: words split at spaces only, each at most 255 bytes
fn nextWord(s: []const u8, i: *usize, out: *[256]u8) []const u8 {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    var n: usize = 0;
    while (i.* < s.len and s[i.*] != 0 and s[i.*] != ' ') : (i.* += 1) {
        if (n < 255) {
            out[n] = s[i.*];
            n += 1;
        }
    }
    return out[0..n];
}

/// file.usd_dump <in> <out> - a USD file's layer as text (tests/usd.py)
fn opUsdDump() void {
    var i: usize = 0;
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const in = nextWord(ops.arg, &i, &b1);
    if (in.len == 0) return;
    const out = nextWord(ops.arg, &i, &b2);
    if (out.len == 0) return;
    const lay = open(in) orelse return app.log("{s}{s}", .{ usdc.err, in });
    defer ul.free(lay);
    if (!@import("files.zig").mayWrite(out)) return app.log("  usd: not written (tests write under /tmp only): {s}", .{out});
    _ = ul.dump(lay, out);
}

/// file.usd_texture_size <n> - the most a USD texture keeps a side
fn opTexSize() void {
    var i: usize = 0;
    var b: [256]u8 = undefined;
    const w = nextWord(ops.arg, &i, &b);
    if (w.len == 0) return;
    const x = @import("ntree.zig").parseFloat(w, null) orelse return;
    const n = @import("ntree.zig").cvtt(x);
    if (n < 0) return;
    usdmat.texcap = @intCast(n);
}

/// file.import_usd <path>: its meshes, materials and physics into a folder;
/// from the UI with none, the file browser; from the console with none, the
/// command half typed.
fn opImportUsd() void {
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.import_usd ~/BeeModel/asset.usd");
        @import("filebrowser.zig").show(.open, "Import USD", ".usd .usda .usdc", "", importLater);
        return;
    }
    importLater(arg);
}

fn importLater(p: []const u8) void {
    @import("jobui.zig").later(importJob, "Importing a USD file", p, 0, 0);
}
fn importJob(p: []const u8, _: usize, _: usize) void {
    importNow(p);
}

/// op_iusd: the import, and "imported <path>" or why not
pub fn importNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = @import("files.zig").expandHome(&eb, p0) orelse p0;
    const r = import(p);
    switch (r) {
        0 => app.log("  imported {s}", .{p}),
        1 => app.log("  could not read {s}", .{p}),
        else => app.log("  not a valid file: {s}", .{p}),
    }
    app.dirty = true;
}
