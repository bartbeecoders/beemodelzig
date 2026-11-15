// The node editor area (nodeed.s): the graph of the active object's material,
// its geometry node tree or its logic graph. Each node a box (header, its
// outputs, its values, its inputs), the Material Output on the right, wires
// from outputs to inputs. Shift+A adds a node at the pointer (a menu, by
// category for materials, typed to search); dragging a header moves a node
// (with the rest of the selection); dragging from an output to an input (or a
// material socket) links them, from a linked input picks the link up (dropped
// elsewhere it is gone, in empty space it opens the menu and links the new
// node); dragging a value sideways changes it; X / Delete removes the
// selection; middle or empty-space drags pan or box-select, the wheel zooms,
// Home fits. Comment frames, reroutes, a knife (Alt), collapse, align,
// copy / paste / duplicate, a palette, the material's preview pane, the nodes'
// thumbnails and a minimap. Every edit goes into the record (MGRF / NTRE) and
// is one undo step.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const sn = @import("shnodes.zig");
const sg = @import("shgraph.zig");
const gops = @import("graphops.zig");
const nt = @import("ntree.zig");
const gn = @import("geonodes.zig");
const logic = @import("logic.zig");
const mods = @import("mods.zig");
const menus = @import("menus.zig");
const cat = @import("catalog.zig");
const tx = @import("text.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const Rect = gfx.Rect;

// --- drawing through the Zui part being described ------------------------------------
// The editor's drawing stays as it was (a canvas's fill, line, text) and goes
// through Zui's painter: `Cv` stands in for BeeModel's canvas.

var Z: *zui.Ui = undefined;

const Cv = struct {
    enabled: bool = true,

    fn fill(_: *const Cv, r: Rect, c: u32) void {
        if (r.w <= 0 or r.h <= 0) return;
        Z.drawRect(.{ .rect = host.zr(r), .fill = host.col(c) });
    }

    fn fillRound(_: *const Cv, r: Rect, rad: i32, c: u32) void {
        if (r.w <= 0 or r.h <= 0) return;
        Z.drawRect(.{ .rect = host.zr(r), .fill = host.col(c), .radius = @floatFromInt(rad) });
    }

    fn line(_: *const Cv, x0_: i32, y0_: i32, x1: i32, y1: i32, c: u32) void {
        const f = struct {
            fn v(a: i32) f32 {
                return @as(f32, @floatFromInt(a)) + 0.5;
            }
        }.v;
        Z.painter().line(.{ .x = f(x0_), .y = f(y0_) }, .{ .x = f(x1), .y = f(y1) }, host.col(c), 1);
    }

    /// Text in the face being used (the node face at the zoom's size).
    fn text(_: *const Cv, x: i32, y: i32, s: []const u8, c: u32) i32 {
        const k = @as(f32, @floatFromInt(@as(u32, @bitCast(facePx())))) / 15.0;
        Z.pushMetric(.font_size, Z.style.font_size * k);
        defer Z.popStyle();
        Z.drawText(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, host.col(c), s);
        return tw(s);
    }

    fn textFit(self: *const Cv, x: i32, y: i32, w: i32, s: []const u8, c: u32) i32 {
        _ = w;
        return self.text(x, y, s, c);
    }
};

var cv_shim: Cv = .{};

/// The size of the face in use, as BeeModel's text sets it (px).
fn facePx() i32 {
    return switch (gfx.face) {
        .node => @max(zs(UI_FONT_PX), 6),
        .small => 13,
        .head => 16,
        .mono => 14,
        else => 15,
    };
}

// --- the records: a material's (material.s) and a tree's (ntree.s), both 4096 bytes ---

pub const Rec = [4096]u8;
const GR_N = 128;
const GR_OUTPOS = 152;
const GR_NODES = 160;
const NODE_SZ = 72;
const ND_IN = 4;
const ND_P = 52;
const ND_POS = 68;
const GR_PINS = 3616;
const NE_FRAMES = 3680;
const NE_NFR = 6;
const FR_SZ = 48;
const NE_NFLAGS = 3968;
const MA_BLEND = 96;
const MA_FUNC = 112;
const NPINS = 13;
const PIN_BASE = 0;
const PIN_EMIT = 4;
const PIN_ALPHA = 5;
const PIN_NORMAL = 6;
const PIN_MASK = 12;

const T_REROUTE = 36; // (matnodes.s: drawn as a knot)
const RR_SZ = 16; // its square (graph units)
const NE_BAR = 20; // the title line
const NW = 170;
const NHDR = 20;
const NROW = 18;
const NSOCK_R = 4;
const COLW = 200;
const MENU_W = 170;
const MROWS = 18;
const CHAR_H = 16;
const UI_FONT_PX = 15;

const COL_NE_BG = 0x23262c;
const COL_NE_GRID = 0x2b2f36;
const COL_NE_KNIFE = 0xe06c75;
const COL_NE_PAL = 0x2a2d34;
const PAL_W = 190;
const PV_SZ = 180;
pub const PV_N = 128;
pub const TH_N = 32;
const TH_G = 54;
const TH_S = 48;
const COL_NE_STAT = 0x9aa1ad;
const COL_NE_WARN = 0xe5a54b;
const PAL_TOP = 34;
const COL_NE_MMBG = 0x1a1c21;
const MM_W = 168;
const MM_H = 104;
const COL_NE_FRBODY = 0x2b3038;
const COL_NE_FRBAR = 0x3a4352;
const COL_NE_BODY = 0x343841;
const COL_NE_EDGE = 0x16181c;
const COL_NE_CONV = 0x2f6589;
const COL_NE_OUT = 0x8a3b3b;
const COL_NE_WIRE = 0xb8bcc4;
const COL_NE_SOCK_C = 0xe3c84a;
const COL_NE_SOCK_V = 0xa1a1a1;
const COL_NE_SOCK_N = 0x6363c7;
const COL_NE_SOCK_G = 0x00d6a3;
const COL_NE_SOCK_R = 0xf0f0f0;
const COL_NE_GEO = 0x1d725e;
const COL_NE_GRP = 0x6e5418;
const kind_col = [5]u32{ COL_NE_SOCK_G, COL_NE_SOCK_V, COL_NE_SOCK_N, COL_NE_SOCK_C, COL_NE_SOCK_R };

const s_ne_keys = "     Shift+A add  X delete  Home fit";
const s_ne_none = "Node editor: the active object's material graph (an object with a material: Properties > Material > New)";
const s_ne_grkeys = "     Shift+A add  X delete  Ctrl+G group  Tab back";
const s_ne_gkeys = "     Shift+A add  X delete  Ctrl+G group  Tab material / into a group";
const s_ne_lkeys = "     Shift+A add  X delete  Tab material  (runs in play mode, F5)";
const out_names = [NPINS][]const u8{ "Base Color", "Metallic", "Specular", "Roughness", "Emission", "Opacity", "Normal", "Ambient Occlusion", "Clear Coat", "Coat Roughness", "Transmission", "IOR", "Opacity Mask" };

// --- the state (nodeed.s's .bss) -------------------------------------------------------

pub var prev_on: u32 = 1; // the preview pane, the thumbnails (on)
pub var thumbs_on: u32 = 1;
pub var pyaw: f32 = 0.6; // the pane's turn
pub var ppitch: f32 = 0.35;
const zsteps = [_]i32{ 25, 33, 50, 67, 75, 90, 100, 110, 125, 150, 175, 200 };
pub var zoom: i32 = 100;
var nw: i32 = NW;
var hdr: i32 = NHDR;
var row: i32 = NROW;
var r2: i32 = NROW / 2;
var hr2: i32 = NHDR + NROW / 2;
var sr: i32 = NSOCK_R;
var pad: i32 = 10;
var ins: i32 = 6;
var ty: i32 = 2;
var hy: i32 = 3;
var sw: i32 = 24;
var h6: i32 = 6;
var grid: i32 = 40;
var txt: bool = true;

// the node clipboard: kind, count, where from, the nodes (internal links: bit 30),
// their places (graph units) and the group's top left
var clipk: u32 = 0;
var clipn: u32 = 0;
var clipm: i32 = 0;
var clipx0: i32 = 0;
var clipy0: i32 = 0;
var clipnodes: [NODE_SZ * 48]u8 = undefined;
var clippos: [48][2]i32 = undefined;
var cmap: [49]u32 = undefined;
pub var panx: i32 = 0; // where graph (0, 0) is, from the body's top left
pub var pany: i32 = 0;
pub var mat: i32 = -1; // the material or tree shown (-1: none)
var n: u32 = 0; // its nodes when laid out
var lx: [49]i32 = @splat(0); // their boxes on screen (0: the output)
var ly: [49]i32 = @splat(0);
var lh: [49]i32 = @splat(0);
var gh: [49]i32 = @splat(0); // heights in the graph
var gx: [49]i32 = @splat(0); // and places in the graph
var gy: [49]i32 = @splat(0);
var depth: [49]i32 = @splat(0);
var coly: [16]i32 = @splat(0);
pub var kind: u32 = 0; // 0 a material's graph, 1 a node tree, 2 a logic graph
pub var pref: u32 = 0; // 1: the material even with a tree
var maxn: u32 = 48;
pub var selm: u64 = 0; // selected nodes (bit n: node n)
pub var path: [8]u32 = @splat(0); // groups entered: their tree numbers + 1
pub var pathn: u32 = 0;
pub var fpath: [8]u32 = @splat(0); // material functions entered (Tab)
pub var fpathn: u32 = 0;
pub var sel: u32 = 0; // the selected node (0: none)
pub var drag: u32 = 0; // 0 none, 1 move, 2 a wire from an output, 3 from an input, 4 from a pin,
//  5 a value, 6 an input's number, 7 pan, 8 a box, 9 the knife, 10 a frame moved,
//  11 resized, 12 the minimap, 13 a palette entry, 14 the preview pane turned
var dn: u32 = 0; // the node dragged (or from)
var dk: u32 = 0; // its socket / value
var cur: ?*const Rec = null; // the record ne_rec found last
pub var pshape: u32 = 0; // (0 sphere, 1 cube, 2 plane)
var prec: ?*const Rec = null;
var pver: u32 = 0;
var pkey_shape: u32 = 0xffffffff;
var pkey_turn: [2]u32 = .{ 0, 0 };
var pbuf: [PV_N * PV_N]u32 = undefined;
var threc: ?*const Rec = null;
var thver: u32 = 0;
var thbuf: [TH_N * TH_N * 48]u32 = undefined;
var pa0: [2]f32 = .{ 0, 0 };
pub var pal: bool = false; // the palette shown, its search, rows scrolled away,
var pfilt: [32]u8 = @splat(0); //  the entry dragged from it
var pfilt_len: usize = 0;
var pscroll: i32 = 0;
var pdent: u32 = 0;
var vclkt: i64 = 0; // the last click on a value: when, which node, which slot
var vclkn: u32 = 0;
var vclkk: u32 = 0;
var px: i32 = 0;
var fitpend: u32 = 0; // a frame asked before a drawing: mode + 1
var arm: bool = false; // a quick key pressed: the entry the next click adds, when
var armq: u32 = 0;
var armt: i64 = 0;
var ne: u32 = 0; // the add menu's entries: type | (preset value + 1) << 8,
var ecat_on: bool = false; //  title, category, rank
var etit: [160][]const u8 = undefined;
var ent: [160]u32 = undefined;
var ecat: [160]u8 = undefined;
var erank: [160]u8 = undefined;
var mmx: i32 = 0; // the minimap on screen (w 0: none), the graph's corner it shows
var mmy: i32 = 0; //  from, its scale (screen px per 1000 graph units)
var mmw: i32 = 0;
var mmh: i32 = 0;
var mmg0: i32 = 0;
var mmg1: i32 = 0;
var mms: i32 = 1;
var clkt: i64 = 0; // the last press in empty space: when, where (a double-click on
var clkx: i32 = 0; //  a wire: a reroute)
var clky: i32 = 0;
var wto: u32 = 0; // the wire found: its input's node (0: a pin), input or pin,
var wk: u32 = 0; //  its output's node and output
var wfrom: u32 = 0;
var wout: u32 = 0;
var ncut: u32 = 0; // wires the knife crossed: node, input
var cutl: [160][2]u32 = undefined;
pub var fsel: u32 = 0; // the selected comment frame + 1
var fmask: u64 = 0; // nodes inside the frame being moved
var fx0: i32 = 0; // its place / size when the drag began
var fy0: i32 = 0;
var fwas: bool = false; // it was selected already (a rename)
var pend: u32 = 0; // a wire dropped in empty space: the node added next is linked
var pnode: u32 = 0; //  (1 from pnode's output pk, 2 into its input pk, 3 to pin pk)
var pk: u32 = 0;
var pick: bool = false; // a link picked up
var ax: i32 = 0; // the pointer when the add menu opened
var ay: i32 = 0;
var sx: [49]i32 = @splat(0); // a selection's places when its move began
var sy: [49]i32 = @splat(0);
var x0: i32 = 0; // the press
var y0: i32 = 0;
var a0: u32 = 0; // what was there: x / pan / value (bits)
var b0: i32 = 0;
var undone: bool = false; // the drag has its undo step
var filt: [32]u8 = @splat(0); // the add menu's search text
var fnl: u32 = 0;
pub var menu: bool = false; // the add menu: open, where
var mx: i32 = 0;
var my: i32 = 0;
var bx: i32 = 0; // the last drawn body
var by: i32 = 0;
var bw: i32 = 0;
var bh: i32 = 0;
var ex: i32 = 0; // the area body (ed_x ...)
var ey: i32 = 0;
var ew: i32 = 0;
var eh: i32 = 0;
var last_mx: i32 = -100000; // (motion: the pointer moved since)
var last_my: i32 = -100000;
var area_i: i16 = -1;

// --- small helpers -------------------------------------------------------------------

fn rd(r: *const Rec, o: usize) u32 {
    return std.mem.readInt(u32, r[o..][0..4], .little);
}
fn rdf(r: *const Rec, o: usize) f32 {
    return @bitCast(rd(r, o));
}
fn rd16(r: *const Rec, o: usize) i32 {
    return std.mem.readInt(i16, r[o..][0..2], .little);
}
fn wr32(r: *Rec, o: usize, v: u32) void {
    std.mem.writeInt(u32, r[o..][0..4], v, .little);
}
fn wr16(r: *Rec, o: usize, v: i32) void {
    std.mem.writeInt(i16, r[o..][0..2], @truncate(v), .little);
}
fn nodeOff(k: u32) usize {
    return GR_NODES + @as(usize, k - 1) * NODE_SZ;
}
fn typeOf(r: *const Rec, k: u32) u32 {
    return rd(r, nodeOff(k));
}
fn nflag(r: *const Rec, k: u32) u8 {
    return r[NE_NFLAGS + k - 1];
}
fn bit(m: u64, k: u32) bool {
    return (m >> @intCast(k & 63)) & 1 != 0;
}
fn bitOf(k: u32) u64 {
    return @as(u64, 1) << @intCast(k & 63);
}

/// cvtss2si: to nearest, ties to even (NaN and out of range: the "integer indefinite").
pub fn cvt(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) r = 2 * @round(x / 2);
    return @intFromFloat(r);
}
/// cvttss2si: toward zero.
fn cvtt(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(@trunc(x));
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// zs: a size at the zoom (rounded as the original: + 50, truncated).
fn zs(v: i32) i32 {
    return @divTrunc(v *% zoom +% 50, 100);
}
/// ne_unzoom: screen pixels to graph units.
fn unzoom(v: i32) i32 {
    return @divTrunc(v *% 100, zoom);
}

// --- the node types: one view of the three catalogues --------------------------------

const MV = struct {
    in: [3]?[]const u8 = .{ null, null, null },
    ik: [3]u8 = .{ 0, 0, 0 },
    val: [4]?[]const u8 = .{ null, null, null, null },
    vk: [4]u8 = .{ 0, 0, 0, 0 },
    ch: []const []const u8 = &.{},
    ch2: []const []const u8 = &.{},
    out: [8]?[]const u8 = @splat(null),
    ok: [8]u8 = @splat(0),
};

// logic.s lg_meta (input kinds 1 value, 2 vector, 4 run; value kinds 0 number,
// 1 choice, 3 whole, 5 name)
const LgM = struct { in: [3]?[]const u8 = .{ null, null, null }, ik: [3]u8 = .{ 0, 0, 0 }, v: [4]?[]const u8 = .{ null, null, null, null }, vk: [4]u8 = .{ 0, 0, 0, 0 }, ch: []const []const u8 = &.{}, out: [3]?[]const u8 = .{ null, null, null }, ok: [3]u8 = .{ 0, 0, 0 } };
const o_then = [3]?[]const u8{ "Then", null, null };
const i_run = [3]?[]const u8{ "Run", null, null };
const v_object = [4]?[]const u8{ "Object", null, null, null };
const v_setp = [4]?[]const u8{ "Property", "Object", null, null };
const ch_byto = [_][]const u8{ "By", "To" };
const ch_repeat = [_][]const u8{ "Once", "Repeat" };
const lg_meta = [logic.NTYPES]LgM{
    .{ .out = o_then, .ok = .{ 4, 0, 0 } }, // begin
    .{ .out = .{ "Then", "Delta", "Time" }, .ok = .{ 4, 1, 1 } }, // tick
    .{ .v = .{ "Key", "When", null, null }, .vk = .{ 3, 1, 0, 0 }, .ch = &.{ "Pressed", "Released", "Held" }, .out = o_then, .ok = .{ 4, 0, 0 } }, // key
    .{ .v = .{ "With", "When", "Margin", null }, .vk = .{ 5, 1, 0, 0 }, .ch = &.{ "Enter", "Leave", "Inside" }, .out = o_then, .ok = .{ 4, 0, 0 } }, // overlap
    .{ .out = o_then, .ok = .{ 4, 0, 0 } }, // hit
    .{ .v = .{ "Seconds", "Repeat", null, null }, .vk = .{ 0, 1, 0, 0 }, .ch = &ch_repeat, .out = o_then, .ok = .{ 4, 0, 0 } }, // timer
    .{ .v = .{ "Name", null, null, null }, .vk = .{ 5, 0, 0, 0 }, .out = .{ "Then", "Value", null }, .ok = .{ 4, 1, 0 } }, // message
    .{ .in = .{ "Run", "Offset", null }, .ik = .{ 4, 2, 0 }, .v = .{ "Mode", null, null, null }, .vk = .{ 1, 0, 0, 0 }, .ch = &ch_byto, .out = o_then, .ok = .{ 4, 0, 0 } }, // move
    .{ .in = .{ "Run", "Degrees", null }, .ik = .{ 4, 2, 0 }, .v = .{ "Mode", null, null, null }, .vk = .{ 1, 0, 0, 0 }, .ch = &ch_byto, .out = o_then, .ok = .{ 4, 0, 0 } }, // rotate
    .{ .in = .{ "Run", "Value", null }, .ik = .{ 4, 1, 0 }, .v = v_setp, .vk = .{ 5, 5, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // set property
    .{ .in = .{ "Run", "Offset", null }, .ik = .{ 4, 2, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // spawn
    .{ .in = i_run, .ik = .{ 4, 0, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // destroy
    .{ .in = i_run, .ik = .{ 4, 0, 0 }, .v = .{ "Action", "Repeat", null, null }, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // play action
    .{ .in = .{ "Run", "Impulse", null }, .ik = .{ 4, 2, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // impulse
    .{ .in = .{ "Run", "Visible", null }, .ik = .{ 4, 1, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // visibility
    .{ .in = .{ "Run", "Value", null }, .ik = .{ 4, 1, 0 }, .v = .{ "Name", "To", null, null }, .vk = .{ 5, 5, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // send
    .{ .in = .{ "Run", "Value", null }, .ik = .{ 4, 2, 0 }, .v = .{ "Variable", "Mode", null, null }, .vk = .{ 3, 1, 0, 0 }, .ch = &.{ "Set", "Add" }, .out = o_then, .ok = .{ 4, 0, 0 } }, // set variable
    .{ .in = .{ "Run", "Condition", null }, .ik = .{ 4, 1, 0 }, .out = .{ "True", "False", null }, .ok = .{ 4, 4, 0 } }, // branch
    .{ .v = .{ "Variable", null, null, null }, .vk = .{ 3, 0, 0, 0 }, .out = .{ "Value", null, null }, .ok = .{ 2, 0, 0 } }, // variable
    .{ .in = .{ "A", "B", null }, .ik = .{ 2, 2, 0 }, .v = .{ "Operation", null, null, null }, .vk = .{ 1, 0, 0, 0 }, .ch = &.{ "Add", "Subtract", "Multiply", "Divide", "Minimum", "Maximum", "Sine", "Cosine", "Greater Than", "Less Than", "Equal", "And", "Or", "Not", "Absolute", "Length", "Distance", "Scale" }, .out = .{ "Result", null, null }, .ok = .{ 2, 0, 0 } }, // math
    .{ .v = .{ "What", null, null, null }, .vk = .{ 1, 0, 0, 0 }, .ch = &.{ "Time", "Delta", "Location", "Rotation", "Start", "Player", "Distance", "Frame", "Random" }, .out = .{ "Value", null, null }, .ok = .{ 2, 0, 0 } }, // info
    .{ .v = v_setp, .vk = .{ 5, 5, 0, 0 }, .out = .{ "Value", null, null }, .ok = .{ 1, 0, 0 } }, // get property
    .{ .in = i_run, .ik = .{ 4, 0, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // shatter
    .{ .in = .{ "Run", "Value", null }, .ik = .{ 4, 1, 0 }, .v = v_object, .vk = .{ 5, 0, 0, 0 }, .out = o_then, .ok = .{ 4, 0, 0 } }, // set strength
    .{ .in = .{ "Point", null, null }, .ik = .{ 2, 0, 0 }, .out = .{ "Force", "Size", null }, .ok = .{ 2, 1, 0 } }, // field
};

/// ne_ntypes: the node types of the kind shown.
fn ntypes() u32 {
    return switch (kind) {
        0 => sn.metas.len,
        1 => gn.NTYPES,
        else => logic.NTYPES,
    };
}

/// ne_title.
fn title(t: u32) []const u8 {
    if (t == 0 or t > ntypes()) return "";
    return switch (kind) {
        0 => sn.metas[t - 1].title,
        1 => gn.titles[t - 1],
        else => logic.titles[t],
    };
}

/// ne_meta_of: a type's row (null: none).
fn metaOf(t: u32) ?MV {
    if (t == 0 or t > ntypes()) return null;
    var v = MV{};
    switch (kind) {
        0 => {
            const s = &sn.metas[t - 1];
            v.in = s.inputs;
            v.ik = s.in_kinds;
            v.val = s.values;
            v.vk = s.val_kinds;
            v.ch = s.choices;
            v.ch2 = s.choices2;
            v.out = s.outputs;
            v.ok = s.out_kinds;
        },
        1 => {
            const s = &gn.meta[t - 1];
            v.in = s.in;
            v.ik = s.in_k[0..3].*;
            v.val = s.val;
            v.vk = s.val_k;
            v.ch = s.choices;
            v.out[0..3].* = s.out;
            v.ok[0..4].* = s.out_k;
        },
        else => {
            const s = &lg_meta[t - 1];
            v.in = s.in;
            v.ik = s.ik;
            v.val = s.v;
            v.vk = s.vk;
            v.ch = s.ch;
            v.out[0..3].* = s.out;
            v.ok[0..3].* = s.ok;
        },
    }
    return v;
}

/// ne_nouts: a type's outputs (materials up to 8, trees 3).
fn nouts(t: u32) u32 {
    const m = metaOf(t) orelse return 0;
    const lim: u32 = if (kind == 0) 8 else 3;
    var k: u32 = 0;
    while (k < lim and m.out[k] != null) k += 1;
    return k;
}

/// ne_counts: inputs and values.
fn counts(t: u32) [2]u32 {
    const m = metaOf(t) orelse return .{ 0, 0 };
    var a: u32 = 0;
    while (a < 3 and m.in[a] != null) a += 1;
    var b: u32 = 0;
    while (b < 4 and m.val[b] != null) b += 1;
    return .{ a, b };
}

fn rows(t: u32) i32 {
    const c = counts(t);
    return @intCast(c[0] + c[1] + nouts(t));
}

/// ne_is_rr: a reroute (a material's knot).
fn isRr(k: u32) bool {
    if (kind != 0 or k == 0) return false;
    const r = cur orelse return false;
    if (k > 48) return false;
    return typeOf(r, k) == T_REROUTE;
}

fn wof(k: u32) i32 {
    return if (isRr(k)) zs(RR_SZ) else nw;
}
fn gwof(k: u32) i32 {
    return if (isRr(k)) RR_SZ else NW;
}

/// ne_compact: half its height on screen when a knot or collapsed (its sockets
/// at that height, on its sides), else 0.
fn compact(k: u32) i32 {
    if (isRr(k)) return zs(RR_SZ) >> 1;
    if (k > 0 and k <= 48) {
        if (cur) |r| {
            if (nflag(r, k) & 1 != 0) return hdr >> 1;
        }
    }
    return 0;
}

fn zoomApply() void {
    nw = zs(NW);
    hdr = zs(NHDR);
    row = zs(NROW);
    r2 = row >> 1;
    hr2 = r2 + hdr;
    sr = @max(zs(NSOCK_R), 2);
    pad = zs(10);
    ins = zs(6);
    h6 = ins;
    sw = zs(24);
    grid = @max(zs(40), 10);
    ty = ((row - CHAR_H) >> 1) + 1;
    hy = ((hdr - CHAR_H) >> 1) + 1;
    txt = zoom >= 50;
    tx.setNodePx(@floatFromInt(@max(zs(UI_FONT_PX), 6)));
}

// --- what is shown ---------------------------------------------------------------

fn matRec(i: usize) ?*const Rec {
    const m = material.get(i) orelse return null;
    return @ptrCast(m);
}

fn objOf() ?*scene.Object {
    const a = scene.active orelse return null;
    if (a >= scene.count) return null;
    return &scene.objects[a];
}

/// ne_rec: the record shown (null: none): a group entered, the active object's
/// logic graph or geometry node tree (unless the material is asked for), a
/// material function entered, else its material's graph.
pub fn rec() ?*const Rec {
    mat = -1;
    kind = 0;
    maxn = 48;
    cur = null;
    if (pathn != 0) {
        const t = path[pathn - 1] -% 1;
        mat = @bitCast(t);
        if (nt.get(t)) |r| {
            kind = 1;
            cur = r;
            return r;
        }
        pathn = 0; // (gone: back out)
        mat = -1;
    }
    const o = objOf() orelse return null;
    if (pref == 0) {
        for (o.mods.m[0..o.mods.n]) |*d| {
            if (d.kind != mods.LOGIC) continue;
            const t = cvtt(mods.getF(d, 0)) -% 1;
            if (t < 0) continue;
            if (!logic.isLogic(@intCast(t))) continue;
            mat = t;
            if (nt.get(@intCast(t))) |r| {
                kind = 2;
                cur = r;
                return r;
            }
        }
        for (o.mods.m[0..o.mods.n]) |*d| {
            if (d.kind != mods.GEONODES) continue;
            const t = cvtt(mods.getF(d, 0)) -% 1;
            if (t < 0) continue;
            mat = t;
            if (nt.get(@intCast(t))) |r| {
                kind = 1;
                cur = r;
                return r;
            }
        }
    }
    if (fpathn != 0) {
        const f = fpath[fpathn - 1];
        if (f < material.count and material.list[f].func == 1) {
            mat = @intCast(f);
            cur = matRec(f);
            return cur;
        }
        fpathn = 0; // (gone: back out)
    }
    if (o.mat == 0 or o.mat > material.count) {
        mat = -1;
        return null;
    }
    mat = o.mat - 1;
    cur = matRec(@intCast(mat));
    return cur;
}

/// ne_own: the record shown, writable (null: none).
fn own() ?*Rec {
    _ = rec() orelse return null;
    if (mat < 0) return null;
    if (kind == 0) {
        const m = material.get(@intCast(mat)) orelse return null;
        material.version +%= 1;
        app.dirty = true;
        return @ptrCast(m);
    }
    const r = nt.own(@intCast(mat)) orelse return null;
    cur = r;
    return r;
}

/// ne_place: a node placed (graph_place / nt_place; trees have no output node).
fn place(k: u32, x: i32, y: i32) void {
    if (mat < 0) return;
    if (kind == 0) {
        _ = gops.place(@intCast(mat), k, x, y);
    } else if (k != 0) {
        _ = nt.place(@intCast(mat), @intCast(k), x, y);
    }
}

// --- the layout (ne_layout) ----------------------------------------------------------

fn height(t: u32) i32 {
    return rows(t) * NROW + NHDR + 6;
}
fn heightS(t: u32) i32 {
    return rows(t) * row + hdr + h6;
}

/// ne_has_thumb: the node shows a thumbnail.
fn hasThumb(k: u32) bool {
    if (kind != 0 or thumbs_on == 0 or k == 0 or k > 48) return false;
    const r = cur orelse return false;
    if (nflag(r, k) & 1 != 0) return false;
    return typeOf(r, k) != T_REROUTE;
}

fn layout(r: *const Rec) void {
    var cnt = rd(r, GR_N);
    if (cnt > maxn) cnt = maxn;
    n = cnt;
    coly = @splat(20);
    depth = @splat(0);
    // depths: 1 + the deepest input (a few passes: links go any way)
    for (0..4) |_| {
        var k: u32 = 0;
        while (k < cnt) : (k += 1) {
            const o = nodeOff(k + 1);
            var d: i32 = 0;
            for (0..3) |c| {
                const l = std.mem.readInt(u16, r[o + ND_IN + c * 16 ..][0..2], .little);
                if (l == 0 or l > cnt) continue;
                d = @max(d, depth[l] + 1);
            }
            depth[k + 1] = @min(d, 15);
        }
    }
    var deepest: i32 = 0;
    var k: u32 = 0;
    while (k < cnt) : (k += 1) {
        const o = nodeOff(k + 1);
        const d = depth[k + 1];
        if (d > deepest) deepest = d;
        const t = rd(r, o);
        var h = height(t);
        const fl = r[NE_NFLAGS + k];
        if (fl & 1 != 0) h = NHDR;
        if (kind == 0) {
            if (t == T_REROUTE) {
                h = RR_SZ;
            } else if (fl & 1 == 0 and thumbs_on != 0) h += TH_G;
        }
        gh[k + 1] = h;
        var x = rd16(r, o + ND_POS);
        var y = rd16(r, o + ND_POS + 2);
        if (x | y == 0) {
            x = d * COLW + 20;
            y = coly[@intCast(d)];
            coly[@intCast(d)] += h + 20;
        }
        gx[k + 1] = x;
        gy[k + 1] = y;
    }
    // the material output
    lh[0] = row * NPINS + hdr + h6;
    gh[0] = NHDR + NPINS * NROW + 6;
    if (kind != 0 or rd(r, MA_FUNC) == 1) {
        lh[0] = 0;
        gh[0] = 0;
        gx[0] = -30000;
        gy[0] = -30000;
    } else {
        var x = rd16(r, GR_OUTPOS);
        var y = rd16(r, GR_OUTPOS + 2);
        if (x | y == 0) {
            const c: i32 = if (cnt != 0) deepest + 1 else 0;
            x = c * COLW + 20;
            y = 20;
        }
        gx[0] = x;
        gy[0] = y;
    }
    // on screen: heights, then places
    k = 1;
    while (k <= cnt) : (k += 1) {
        var h = heightS(typeOf(r, k));
        if (r[NE_NFLAGS + k - 1] & 1 != 0) h = hdr;
        if (isRr(k)) {
            h = zs(RR_SZ);
        } else if (hasThumb(k)) h += zs(TH_G);
        lh[k] = h;
    }
    k = 0;
    while (k <= cnt) : (k += 1) {
        lx[k] = zs(gx[k]) +% bx +% panx;
        ly[k] = zs(gy[k]) +% by +% pany;
    }
}

/// ne_out_xy: output k's socket on screen.
fn outXY(k: u32, o: u32) [2]i32 {
    const c = compact(k);
    const x = lx[k] + wof(k);
    if (c != 0) return .{ x, ly[k] + c };
    return .{ x, ly[k] + hr2 + @as(i32, @intCast(o)) * row };
}

/// ne_in_xy: input (or, node 0, pin) k's socket on screen.
fn inXY(r: *const Rec, k: u32, i: u32) [2]i32 {
    const c = compact(k);
    if (c != 0) return .{ lx[k], ly[k] + c };
    var j: i32 = @intCast(i);
    if (k != 0) {
        const t = typeOf(r, k);
        j += @intCast(nouts(t) + counts(t)[1]);
    }
    return .{ lx[k], ly[k] + hr2 + j * row };
}

// --- wires ------------------------------------------------------------------------

/// ne_bez: the wire's cubic Bezier (handles max(the grid step, |dx| / 2)), 17 points.
fn bez(xa: i32, ya: i32, xb: i32, yb: i32, out: *[17][2]i32) void {
    const d: u32 = @abs(xb -% xa);
    var hh: i32 = @bitCast(d >> 1);
    if (hh < grid) hh = grid;
    out[0] = .{ xa, ya };
    const fxa: f32 = @floatFromInt(xa);
    const fya: f32 = @floatFromInt(ya);
    const fxb: f32 = @floatFromInt(xb);
    const fyb: f32 = @floatFromInt(yb);
    const fh: f32 = @floatFromInt(hh);
    var i: u32 = 1;
    while (i <= 16) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * 0.0625;
        const s = 1.0 - t;
        const b0_ = s * s * s;
        const b1 = s * s * t * 3.0;
        const b2 = s * t * t * 3.0;
        const b3 = t * t * t;
        var x = fxa * b0_;
        x += (fxa + fh) * b1;
        x += (fxb - fh) * b2;
        x += fxb * b3;
        const y = (b0_ + b1) * fya + (b2 + b3) * fyb;
        out[i] = .{ cvt(x), cvt(y) };
    }
}

fn wire(xa: i32, ya: i32, xb: i32, yb: i32, col: u32) void {
    var p: [17][2]i32 = undefined;
    bez(xa, ya, xb, yb, &p);
    var q: [17]zui.Vec2 = undefined;
    for (p, &q) |a, *b| b.* = .{ .x = @as(f32, @floatFromInt(a[0])) + 0.5, .y = @as(f32, @floatFromInt(a[1])) + 0.5 };
    Z.painter().polyline(&q, host.col(col), 1, false);
}

/// seg_near: the point within 6 px of the segment.
fn segNear(p: [2]i32, q: [2]i32, ptx: i32, pty: i32) bool {
    const p0: f32 = @floatFromInt(p[0]);
    const p1: f32 = @floatFromInt(p[1]);
    const dx: f32 = @as(f32, @floatFromInt(q[0])) - p0;
    const dy: f32 = @as(f32, @floatFromInt(q[1])) - p1;
    var wx: f32 = @as(f32, @floatFromInt(ptx)) - p0;
    var wy: f32 = @as(f32, @floatFromInt(pty)) - p1;
    var t = dx * wx + dy * wy;
    const dd = dx * dx + dy * dy;
    if (dd > 0) {
        t = t / dd;
        t = maxss(t, 0);
        t = minss(t, 1);
    } else t = 0;
    wx -= dx * t;
    wy -= dy * t;
    const e = wx * wx + wy * wy;
    return !(e > 36.0);
}

/// orient: the sign of (b - a) x (c - a).
fn orient(ax_: i32, ay_: i32, bx_: i32, by_: i32, cx: i32, cy: i32) i32 {
    const v = (@as(i64, bx_) - ax_) * (@as(i64, cy) - ay_) - (@as(i64, by_) - ay_) * (@as(i64, cx) - ax_);
    return if (v == 0) 0 else if (v > 0) 1 else -1;
}

/// seg_cross: the knife (x0, y0 -> the pointer) and the segment cross.
fn segCross(p: [2]i32, q: [2]i32) bool {
    const kx = ui.mx;
    const ky = ui.my;
    if (orient(x0, y0, kx, ky, p[0], p[1]) * orient(x0, y0, kx, ky, q[0], q[1]) > 0) return false;
    if (orient(p[0], p[1], q[0], q[1], x0, y0) * orient(p[0], p[1], q[0], q[1], kx, ky) > 0) return false;
    return true;
}

/// One wire (to node k's input / pin i, from node `from`'s output `out`): mode 0
/// true when the pointer is on it, mode 1 adds it to cutl when the knife crosses it.
fn wsOne(r: *const Rec, k: u32, i: u32, from: u32, out: u32, mode: u32) bool {
    const b = inXY(r, k, i);
    const a = outXY(from, out);
    var p: [17][2]i32 = undefined;
    bez(a[0], a[1], b[0], b[1], &p);
    for (0..16) |s| {
        if (mode == 0) {
            if (segNear(p[s], p[s + 1], ui.mx, ui.my)) return true;
        } else if (segCross(p[s], p[s + 1])) {
            if (ncut >= 160) return false;
            cutl[ncut] = .{ k, i };
            ncut += 1;
            return false;
        }
    }
    return false;
}

/// ne_wire_scan: mode 0 the wire within 6 px of the pointer (wto, wk, wfrom,
/// wout): 1 found; mode 1 every wire the knife crosses (cutl): the count.
fn wireScan(mode: u32) u32 {
    ncut = 0;
    const r = rec() orelse return 0;
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        const ni = counts(typeOf(r, k))[0];
        var i: u32 = 0;
        while (i < ni) : (i += 1) {
            const l = rd(r, nodeOff(k) + ND_IN + i * 16);
            const from = l & 0xffff;
            const out = (l >> 16) & 0xff;
            if (from == 0 or from > n) continue;
            if (wsOne(r, k, i, from, out, mode)) {
                wto = k;
                wk = i;
                wfrom = from;
                wout = out;
                return 1;
            }
        }
    }
    if (kind != 0) return ncut;
    var i: u32 = 0;
    while (i < NPINS) : (i += 1) {
        const l = rd(r, GR_PINS + i * 4);
        const from = l & 0xffff;
        const out = (l >> 16) & 0xff;
        if (from == 0 or from > n) continue;
        if (wsOne(r, 0, i, from, out, mode)) {
            wto = 0;
            wk = i;
            wfrom = from;
            wout = out;
            return 1;
        }
    }
    return ncut;
}

/// ne_cut: the links in cutl gone (inputs back to their constants, pins
/// unplugged): one undo step.
fn cutLinks() void {
    if (ncut == 0) return;
    undo.label("Cut Links");
    const r = own() orelse return;
    for (cutl[0..ncut]) |c| {
        if (c[0] == 0) {
            wr32(r, GR_PINS + c[1] * 4, 0);
        } else wr32(r, nodeOff(c[0]) + ND_IN + c[1] * 16, 0);
    }
    app.dirty = true;
}

/// ne_reroute: a knot on the wire found (materials): its output -> the knot ->
/// the input or pin, one undo step.
fn reroute() void {
    if (kind != 0) return;
    const r = rec() orelse return;
    if (rd(r, GR_N) >= maxn) return;
    undo.label("Add Reroute");
    const mi: usize = @intCast(mat);
    const k = gops.add(mi, T_REROUTE) orelse return;
    const x = unzoom(ui.mx - bx - panx) - RR_SZ / 2;
    const y = unzoom(ui.my - by - pany) - RR_SZ / 2;
    _ = gops.place(mi, k, x, y);
    _ = gops.link(mi, wfrom, k, 1, wout); // (the knot is the last: nothing renumbered)
    if (wto == 0) {
        _ = gops.socket(mi, wk, k, 0);
    } else _ = gops.link(mi, k, wto, wk + 1, 0);
    app.dirty = true;
    selm = 0;
}

// --- the minimap -------------------------------------------------------------------

fn mmX(v: i32) i32 {
    return @divTrunc((v -% mmg0) *% mms, 1000) + mmx + 4;
}
fn mmY(v: i32) i32 {
    return @divTrunc((v -% mmg1) *% mms, 1000) + mmy + 4;
}

fn addgw(v: i32, k: u32) i32 {
    return v +% gwof(k);
}

/// ne_draw_minimap: the whole graph small in the bottom right corner, the view's
/// rectangle on it (bodies narrower than 480 px or lower than 320: none).
fn drawMinimap(r: *const Rec) void {
    const cv = &cv_shim;
    mmw = 0;
    if (bw < 480 or bh < 320 or n == 0) return;
    var gx0: i32 = std.math.maxInt(i32);
    var gy0: i32 = std.math.maxInt(i32);
    var gx1: i32 = std.math.minInt(i32);
    var gy1: i32 = std.math.minInt(i32);
    var k: u32 = if (kind == 0) 0 else 1;
    while (k <= n) : (k += 1) {
        gx0 = @min(gx0, gx[k]);
        gx1 = @max(gx1, addgw(gx[k], k));
        gy0 = @min(gy0, gy[k]);
        gy1 = @max(gy1, gy[k] +% gh[k]);
    }
    const v0 = unzoom(0 -% panx);
    const v2 = unzoom(bw -% panx);
    const v1 = unzoom(0 -% pany);
    const v3 = unzoom(bh -% pany);
    gx0 = @min(gx0, v0);
    gx1 = @max(gx1, v2);
    gy0 = @min(gy0, v1);
    gy1 = @max(gy1, v3);
    mmg0 = gx0;
    mmg1 = gy0;
    var s = @divTrunc(@as(i32, (MM_W - 8) * 1000), gx1 -% gx0 +% 1);
    const s2 = @divTrunc(@as(i32, (MM_H - 8) * 1000), gy1 -% gy0 +% 1);
    if (s2 < s) s = s2;
    if (s <= 0) return;
    mms = s;
    mmx = bx + bw - (MM_W + 8);
    mmy = by + bh - (MM_H + 8);
    mmw = MM_W;
    mmh = MM_H;
    cv.fill(.{ .x = mmx, .y = mmy, .w = MM_W, .h = MM_H }, COL_NE_MMBG);
    k = if (kind == 0) 0 else 1;
    while (k <= n) : (k += 1) {
        const x = mmX(gx[k]);
        const y = mmY(gy[k]);
        const w = @divTrunc(gwof(k) *% s, 1000) + 1;
        const h = @divTrunc(gh[k] *% s, 1000) + 1;
        var col: u32 = COL_NE_OUT;
        if (k != 0) {
            col = COL_NE_GEO;
            if (kind == 0) {
                const t = typeOf(r, k);
                col = if (t >= 1 and t <= sn.metas.len) sn.metas[t - 1].color else 0;
            }
        }
        cv.fill(.{ .x = x, .y = y, .w = w, .h = h }, col);
    }
    const ax_ = mmX(v0);
    const ay_ = mmY(v1);
    const bx_ = mmX(v2);
    const by_ = mmY(v3);
    const acc = ui.th.accent;
    cv.fill(.{ .x = ax_, .y = ay_, .w = bx_ - ax_, .h = 1 }, acc);
    cv.fill(.{ .x = ax_, .y = by_, .w = bx_ - ax_, .h = 1 }, acc);
    cv.fill(.{ .x = ax_, .y = ay_, .w = 1, .h = by_ - ay_ }, acc);
    cv.fill(.{ .x = bx_, .y = ay_, .w = 1, .h = by_ - ay_ + 1 }, acc);
}

fn inMinimap(x: i32, y: i32) bool {
    if (mmw == 0) return false;
    const a = x - mmx;
    const b = y - mmy;
    return a >= 0 and a < mmw and b >= 0 and b < mmh;
}

/// ne_minimap_go: the view centred on the graph point under the pointer.
fn minimapGo(x: i32, y: i32) void {
    const g0 = @divTrunc((x - mmx - 4) *% 1000, mms) +% mmg0;
    panx = (bw >> 1) - zs(g0);
    const g1 = @divTrunc((y - mmy - 4) *% 1000, mms) +% mmg1;
    pany = (bh >> 1) - zs(g1);
    app.dirty = true;
}

// --- previews: the nodes' thumbnails, the material's pane ----------------------------

/// ne_make_thumbs: the thumbnails again when the graph changed since.
fn makeThumbs(r: *const Rec) void {
    if (kind != 0 or thumbs_on == 0 or rd(r, GR_N) == 0) return;
    if (threc == r and thver == material.version) return;
    threc = r;
    thver = material.version;
    const ma: *const material.Material = @ptrCast(@alignCast(r));
    sg.thumbs(ma, material.list[0..material.count], &thbuf, TH_N);
    for (&thbuf) |*p| p.* |= 0xff000000; // (opaque, for Zui's images)
}

/// ne_blit: an image (n x n) scaled to the screen (nearest): a Zui image
/// over the pixels (opaque: their alpha set when they are made).
fn blit(img: []const u32, nn: i32, x: i32, y: i32, size: i32) void {
    if (size <= 0 or nn <= 0) return;
    const im = Z.frameAllocator().create(zui.Image) catch return;
    im.* = .initArgb(img, @intCast(nn), @intCast(nn));
    im.is_opaque = true;
    Z.painter().image(im, .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(size), .h = @floatFromInt(size) }, .{ .filter = .nearest });
}

fn drawThumb(r: *const Rec, k: u32) void {
    if (!hasThumb(k)) return;
    if (threc != r) return;
    const size = zs(TH_S);
    const x = ((wof(k) - size) >> 1) + lx[k];
    const y = ly[k] + lh[k] - size - zs(4);
    const o: usize = @as(usize, k - 1) * TH_N * TH_N;
    blit(thbuf[o .. o + TH_N * TH_N], TH_N, x, y, size);
}

/// ne_pane_box: the preview pane's top left, null: none (not a material, off, too narrow).
fn paneBox() ?[2]i32 {
    if (kind != 0 or prev_on == 0) return null;
    if (bw < PV_SZ + 260 or bh < PV_SZ + 40) return null;
    return .{ bx + bw - (PV_SZ + 8), by + 8 };
}

fn inPane(x: i32, y: i32) bool {
    const p = paneBox() orelse return false;
    const a = x - p[0];
    const b = y - p[1];
    return a >= 0 and a < PV_SZ and b >= 0 and b < PV_SZ;
}

fn paneTurn(x: i32, y: i32) void {
    pyaw = @as(f32, @floatFromInt(x - x0)) * 0.01 + pa0[0];
    var p = @as(f32, @floatFromInt(y - y0)) * 0.01 + pa0[1];
    p = maxss(p, -1.5);
    p = minss(p, 1.5);
    ppitch = p;
    app.dirty = true;
}

/// ne_draw_pane: the material in the corner (made again when the graph, the shape
/// or the turn changed).
fn drawPane(r: *const Rec) void {
    const p = paneBox() orelse return;
    const tk: [2]u32 = .{ @bitCast(pyaw), @bitCast(ppitch) };
    if (prec != r or pver != material.version or pkey_shape != pshape or pkey_turn[0] != tk[0] or pkey_turn[1] != tk[1]) {
        prec = r;
        pver = material.version;
        pkey_shape = pshape;
        pkey_turn = tk;
        const ma: *const material.Material = @ptrCast(@alignCast(r));
        @import("preview.zig").materialBall(ma, &pbuf, PV_N, pshape, pyaw, ppitch);
        for (&pbuf) |*q| q.* |= 0xff000000; // (opaque, for Zui's images)
    }
    cv_shim.fill(.{ .x = p[0] - 1, .y = p[1] - 1, .w = PV_SZ + 2, .h = PV_SZ + 2 }, COL_NE_EDGE);
    blit(&pbuf, PV_N, p[0], p[1], PV_SZ);
}

// --- text: the original's fmt_* into a buffer --------------------------------------

const Fmt = struct {
    b: [160]u8 = undefined,
    l: usize = 0,
    fn ch(f: *Fmt, c: u8) void {
        if (f.l < f.b.len) {
            f.b[f.l] = c;
            f.l += 1;
        }
    }
    fn str(f: *Fmt, t: []const u8) void {
        for (t) |c| f.ch(c);
    }
    fn int(f: *Fmt, v: i32) void {
        var u: u32 = @bitCast(v);
        if (v < 0) {
            f.ch('-');
            u = 0 -% u;
        }
        var d: [12]u8 = undefined;
        var k: usize = 0;
        while (true) {
            d[k] = @intCast('0' + u % 10);
            k += 1;
            u /= 10;
            if (u == 0) break;
        }
        while (k > 0) {
            k -= 1;
            f.ch(d[k]);
        }
    }
    fn uint(f: *Fmt, v: u32) void {
        f.int(@bitCast(v));
    }
    /// ne_fmt_num: 2 decimals (0 from 100).
    fn num(f: *Fmt, v: f32) void {
        if (!(@abs(v) < 100.0)) {
            f.int(cvt(v));
            return;
        }
        var b: i32 = cvt(v * 100.0);
        if (b < 0) {
            f.ch('-');
            b = -b;
        }
        const u: u32 = @intCast(b);
        f.uint(u / 100);
        f.ch('.');
        f.ch(@intCast('0' + (u % 100) / 10));
        f.ch(@intCast('0' + (u % 100) % 10));
    }
    /// ne_fmt_num_append: 4 decimals.
    fn num4(f: *Fmt, v: f32) void {
        var b: u32 = @bitCast(cvt(v * 10000.0));
        if (@as(i32, @bitCast(b)) < 0) {
            f.ch('-');
            b = 0 -% b;
        }
        f.uint(b / 10000);
        f.ch('.');
        var rest = b % 10000;
        var c: u32 = 1000;
        while (c != 0) {
            f.ch(@intCast('0' + rest / c));
            rest %= c;
            c /= 10;
        }
    }
    /// fmt_fix1.
    fn fix1(f: *Fmt, v: f32) void {
        var b: u32 = @bitCast(cvt(v * 10.0));
        if (@as(i32, @bitCast(b)) < 0) {
            f.ch('-');
            b = 0 -% b;
        }
        f.uint(b / 10);
        f.ch('.');
        f.ch(@intCast('0' + b % 10));
    }
    fn s(f: *const Fmt) []const u8 {
        return f.b[0..f.l];
    }
};

/// text_width: the advances summed, rounded (not cut up as gfx.textWidth).
fn tw(s: []const u8) i32 {
    if (!tx.loaded) return gfx.textWidth(s);
    var pen: i64 = 0;
    var i: usize = 0;
    while (i < s.len) pen += @as(i64, @intFromFloat(@round(tx.glyph(gfx.face, tx.nextCp(s, &i)).adv * 65536.0)));
    return @intFromFloat(@floor(@as(f64, @floatFromInt(pen)) / 65536.0 / tx.ui_scale + 0.5));
}

/// draw_text: the pen after it.
fn text(x: i32, y: i32, s: []const u8, col: u32) i32 {
    _ = cv_shim.text(x, y, s, col);
    return x + tw(s);
}

fn rightText(s: []const u8, right: i32, y: i32, col: u32) void {
    _ = cv_shim.text(right - tw(s), y, s, col);
}

/// ne_rgb: linear colour to 0xRRGGBB (sqrt as gamma).
fn rgb(v: [3]f32) u32 {
    var c: u32 = 0;
    for (v) |x0_| {
        var x = maxss(x0_, 0);
        x = minss(x, 1);
        x = @sqrt(x) * 255.0;
        c = (c << 8) | (@as(u32, @bitCast(cvt(x))) & 0xff);
    }
    return c;
}

fn sock(x: i32, y: i32, col: u32) void {
    cv_shim.fill(.{ .x = x - sr, .y = y - sr, .w = sr * 2 + 1, .h = sr * 2 + 1 }, col);
}

/// ne_value_text: a node's value p as text (a number, a choice, an image's, a
/// tree's or a function's name, a logic name).
fn valueText(r: *const Rec, k: u32, p: u32, f: *Fmt) []const u8 {
    const o = nodeOff(k);
    const m = metaOf(rd(r, o)) orelse return "";
    const v = rdf(r, o + ND_P + p * 4);
    const vk = m.vk[p];
    switch (vk) {
        1, 6 => {
            const l = if (vk == 6) m.ch2 else m.ch;
            if (l.len == 0) return "";
            var i: i32 = cvt(v);
            if (i < 0) i = 0;
            var u: usize = @intCast(i);
            if (u >= l.len) u = l.len - 1;
            return l[u];
        },
        2 => {
            const i = cvt(v) -% 1;
            if (i < 0 or i >= images.count) return "(none)";
            return images.nameOf(@intCast(i));
        },
        4 => {
            const i = cvt(v) -% 1;
            if (i < 0) return "(none)";
            if (kind == 0) {
                if (i >= material.count) return "(none)";
                return material.list[@intCast(i)].nameOf();
            }
            const tr = nt.get(@intCast(i)) orelse return "(none)";
            return nt.name(tr);
        },
        5 => return logic.nameOf(r, cvt(v)) orelse "none",
        3 => {
            f.int(cvt(v));
            return f.s();
        },
        else => {
            f.num(v);
            return f.s();
        },
    }
}

// --- drawing ------------------------------------------------------------------------

/// ne_box: the frame, header and title (node 0: the output).
fn box(k: u32, hcol: u32, ttl: []const u8) void {
    const cv = &cv_shim;
    const w = wof(k);
    const edge: u32 = if (k != 0 and bit(selm, k)) ui.th.accent else COL_NE_EDGE;
    cv.fill(.{ .x = lx[k] - 1, .y = ly[k] - 1, .w = w + 2, .h = lh[k] + 2 }, edge);
    if (isRr(k)) {
        cv.fill(.{ .x = lx[k], .y = ly[k], .w = w, .h = lh[k] }, COL_NE_WIRE);
        return;
    }
    cv.fill(.{ .x = lx[k], .y = ly[k], .w = w, .h = lh[k] }, COL_NE_BODY);
    cv.fill(.{ .x = lx[k], .y = ly[k], .w = w, .h = hdr }, hcol);
    _ = text(lx[k] + ins, ly[k] + hy, ttl, ui.th.text);
}

fn headerColour(t: u32) u32 {
    return switch (kind) {
        0 => if (t >= 1 and t <= sn.metas.len) sn.metas[t - 1].color else 0,
        2 => if (t <= 7) COL_NE_OUT else if (t <= 18) COL_NE_GEO else COL_NE_CONV,
        else => if (t == 26) COL_NE_GRP else if (t <= 2) COL_NE_OUT else if (t <= 15) COL_NE_GEO else COL_NE_CONV,
    };
}

/// ne_draw_node: node k (1..n).
fn drawNode(r: *const Rec, k: u32) void {
    const cv = &cv_shim;
    const th = ui.th;
    const o = nodeOff(k);
    const t = rd(r, o);
    const m = metaOf(t) orelse return drawThumb(r, k);
    const no = nouts(t);
    const c = counts(t);
    var ttl = title(t);
    var pb: [24]u8 = undefined;
    if (kind == 0 and t >= 37 and t <= 39) {
        const nm = gops.paramName(@ptrCast(@alignCast(&r[o])), &pb);
        if (nm.len > 0) ttl = nm;
    }
    box(k, headerColour(t), ttl);
    if (compact(k) != 0) {
        if (no != 0) {
            const p = outXY(k, 0);
            sock(p[0], p[1], COL_NE_WIRE);
        }
        if (c[0] != 0) {
            const p = inXY(r, k, 0);
            sock(p[0], p[1], COL_NE_WIRE);
        }
        return drawThumb(r, k);
    }
    const x = lx[k];
    const top = ly[k] + hdr;
    // the outputs
    var i: u32 = 0;
    while (i < no) : (i += 1) {
        if (txt) rightText(m.out[i].?, x + nw - pad, @as(i32, @intCast(i)) * row + top + ty, th.text);
        const p = outXY(k, i);
        sock(p[0], p[1], kind_col[@min(m.ok[i], 4)]);
    }
    // the values
    i = 0;
    while (i < c[1]) : (i += 1) {
        const ry = @as(i32, @intCast(no + i)) * row + top;
        cv.fill(.{ .x = x + ins, .y = ry + 1, .w = nw - ins - ins, .h = row - 2 }, th.field);
        if (!txt) continue;
        _ = text(x + pad, ry + ty, m.val[i].?, th.text_dim);
        var f = Fmt{};
        rightText(valueText(r, k, i, &f), x + nw - pad, ry + ty, th.text);
    }
    // the inputs
    i = 0;
    while (i < c[0]) : (i += 1) {
        const ry = @as(i32, @intCast(c[1] + no + i)) * row + top;
        const ik = m.ik[i];
        sock(x, ry + r2, kind_col[@min(ik, 4)]);
        if (!txt) continue;
        _ = text(x + pad, ry + ty, m.in[i].?, th.text);
        const io = o + ND_IN + i * 16;
        if (rd(r, io) != 0) continue; // (linked)
        switch (ik) {
            1 => {
                var f = Fmt{};
                f.num(rdf(r, io + 4));
                rightText(f.s(), x + nw - pad, ry + ty, th.text_dim);
            },
            2 => {
                if (kind == 0) continue;
                var f = Fmt{};
                const s = if (kind == 1 and t == 24 and i == 0) "position" else blk: {
                    for (0..3) |q| {
                        f.fix1(rdf(r, io + 4 + q * 4));
                        if (q != 2) f.ch(' ');
                    }
                    break :blk f.s();
                };
                rightText(s, x + nw - pad, ry + ty, th.text_dim);
            },
            3 => {
                const col = rgb(.{ rdf(r, io + 4), rdf(r, io + 8), rdf(r, io + 12) });
                cv.fill(.{ .x = x + nw - pad - sw, .y = ry + (row >> 2), .w = sw, .h = r2 }, col);
            },
            else => {},
        }
    }
    drawThumb(r, k);
}

/// ne_draw_output: the Material Output node.
fn drawOutput(r: *const Rec) void {
    const th = ui.th;
    box(0, COL_NE_OUT, "Material Output");
    const blend = cvt(rdf(r, MA_BLEND));
    var i: u32 = 0;
    while (i < NPINS) : (i += 1) {
        const p = inXY(r, 0, i);
        const col: u32 = if (i == PIN_BASE or i == PIN_EMIT) COL_NE_SOCK_C else if (i == PIN_NORMAL) COL_NE_SOCK_N else COL_NE_SOCK_V;
        sock(p[0], p[1], col);
        if (!txt) continue;
        var tc = th.text;
        if (i == PIN_ALPHA and blend != 2) tc = th.text_dim;
        if (i == PIN_MASK and blend != 1) tc = th.text_dim;
        _ = text(p[0] + pad, p[1] - r2 + ty, out_names[i], tc);
    }
}

/// ne_draw_stats: a line at the bottom left: the nodes, how many lead to the
/// output, the texture samples; warnings in amber.
fn drawStats(r: *const Rec) void {
    if (kind != 0) return;
    const cnt = rd(r, GR_N);
    if (cnt == 0) return;
    const ma: *const material.Material = @ptrCast(@alignCast(r));
    var want: u64 = 0;
    if (rd(r, MA_FUNC) == 1) {
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            if (rd(r, GR_NODES + @as(usize, i) * NODE_SZ) == 41) want |= bitOf(i);
        }
    } else {
        for (0..NPINS) |p| {
            const l = std.mem.readInt(u16, r[GR_PINS + p * 4 ..][0..2], .little);
            if (l == 0) continue;
            want |= bitOf(l - 1);
        }
    }
    const live = sg.liveOf(ma, want);
    const nlive: u32 = @popCount(live);
    var tex: u32 = 0;
    var noimg: u32 = 0;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        const o = GR_NODES + @as(usize, i) * NODE_SZ;
        const t = rd(r, o);
        if (t != 1 and t != 35) continue;
        if (bit(live, i)) tex += 1;
        if (rd(r, o + ND_P) == 0) noimg += 1;
    }
    const old = gfx.useFace(.small);
    defer _ = gfx.useFace(old);
    var f = Fmt{};
    f.uint(cnt);
    f.str(" nodes, ");
    f.uint(nlive);
    f.str(" lead to the output, texture samples: ");
    f.uint(tex);
    const y = by + bh - 20;
    var pen = text(bx + 8, y, f.s(), COL_NE_STAT);
    if (cnt != nlive) {
        var g = Fmt{};
        g.str("  - ");
        g.uint(cnt -% nlive);
        g.str(" lead nowhere");
        pen = text(pen, y, g.s(), COL_NE_WARN);
    }
    if (noimg != 0) _ = text(pen, y, "  - a texture sample has no image", COL_NE_WARN);
}

/// ne_draw_box: the selection box being dragged (an outline).
fn drawBox() void {
    const cv = &cv_shim;
    var xa = x0;
    var xb = ui.mx;
    if (xa > xb) std.mem.swap(i32, &xa, &xb);
    var ya = y0;
    var yb = ui.my;
    if (ya > yb) std.mem.swap(i32, &ya, &yb);
    const w = xb - xa + 1;
    const h = yb - ya + 1;
    const acc = ui.th.accent;
    cv.fill(.{ .x = xa, .y = ya, .w = w, .h = 1 }, acc);
    cv.fill(.{ .x = xa, .y = ya + h - 1, .w = w, .h = 1 }, acc);
    cv.fill(.{ .x = xa, .y = ya, .w = 1, .h = h }, acc);
    cv.fill(.{ .x = xa + w - 1, .y = ya, .w = 1, .h = h }, acc);
}

/// ne_wire_col: the output's kind, the accent at a selected node.
fn wireCol(r: *const Rec, from: u32, out: u32, to: u32) u32 {
    if (bit(selm, from) or bit(selm, to)) return ui.th.accent;
    if (from == 0 or from > 48) return COL_NE_WIRE;
    const m = metaOf(typeOf(r, from)) orelse return COL_NE_WIRE;
    const k = if (out < 8) m.ok[out] else 0xff;
    if (k > 4) return COL_NE_WIRE;
    return kind_col[k];
}

// --- comment frames -------------------------------------------------------------------

fn frScr(r: *const Rec, f: u32) Rect {
    const o = NE_FRAMES + @as(usize, f) * FR_SZ;
    return .{ .x = zs(rd16(r, o)) + bx + panx, .y = zs(rd16(r, o + 2)) + by + pany, .w = zs(rd16(r, o + 4)), .h = zs(rd16(r, o + 6)) };
}

/// ne_draw_frames: a body, a title bar with the title, a grip at the corner; the
/// selected one outlined.
fn drawFrames(r: *const Rec) void {
    const cv = &cv_shim;
    var f: u32 = 0;
    while (f < NE_NFR) : (f += 1) {
        const o = NE_FRAMES + @as(usize, f) * FR_SZ;
        if (rd16(r, o + 4) <= 0) continue;
        const s = frScr(r, f);
        if (f + 1 == fsel) cv.fill(.{ .x = s.x - 2, .y = s.y - 2, .w = s.w + 4, .h = s.h + 4 }, ui.th.accent);
        var col = rd(r, o + 8);
        if (col == 0) col = COL_NE_FRBODY;
        cv.fill(s, col);
        cv.fill(.{ .x = s.x, .y = s.y, .w = s.w, .h = hdr + 4 }, COL_NE_FRBAR);
        cv.fill(.{ .x = s.x + s.w - 8, .y = s.y + s.h - 8, .w = 6, .h = 6 }, COL_NE_FRBAR);
        _ = text(s.x + 8, s.y + hy + 2, std.mem.sliceTo(r[o + 12 .. o + 48], 0), ui.th.text);
    }
}

/// ne_frame_hit: 1 a frame's title bar, 2 its corner; the frame (the top one).
fn frameHit(x: i32, y: i32) ?[2]u32 {
    const r = rec() orelse return null;
    var f: u32 = NE_NFR;
    while (f > 0) {
        f -= 1;
        const o = NE_FRAMES + @as(usize, f) * FR_SZ;
        if (rd16(r, o + 4) <= 0) continue;
        const s = frScr(r, f);
        const a = x - s.x;
        const b = y - s.y;
        if (a < 0 or a >= s.w or b < 0 or b >= s.h) continue;
        if (s.w - a <= 12 and s.h - b <= 12) return .{ 2, f };
        if (b >= hdr + 4) continue; // (the body: through to a box select)
        return .{ 1, f };
    }
    return null;
}

/// ne_frame_grab: a drag begins: its place (or size), the nodes wholly inside.
fn frameGrab(f: u32) void {
    const r = rec() orelse return;
    const o = NE_FRAMES + @as(usize, f) * FR_SZ;
    fx0 = rd16(r, o);
    fy0 = rd16(r, o + 2);
    if (drag == 11) {
        fx0 = rd16(r, o + 4);
        fy0 = rd16(r, o + 6);
    }
    var m: u64 = 0;
    var k: u32 = 0;
    while (k <= n) : (k += 1) {
        sx[k] = gx[k];
        sy[k] = gy[k];
        const fx = rd16(r, o);
        const fy = rd16(r, o + 2);
        if (gx[k] < fx) continue;
        if (addgw(gx[k], k) > fx +% rd16(r, o + 4)) continue;
        if (gy[k] < fy) continue;
        if (gy[k] +% gh[k] > fy +% rd16(r, o + 6)) continue;
        m |= bitOf(k);
    }
    if (kind != 0) m &= ~@as(u64, 1);
    fmask = m;
}

/// ne_frame_drag: moving a frame (and its nodes) or resizing it.
fn frameDrag(x: i32, y: i32) void {
    firstChange();
    const ddx = unzoom(x - x0);
    const ddy = unzoom(y - y0);
    const r = own() orelse return;
    const o = NE_FRAMES + @as(usize, dk) * FR_SZ;
    var a = fx0 +% ddx;
    var b = fy0 +% ddy;
    if (drag == 11) {
        if (a < 80) a = 80;
        if (b < 60) b = 60;
        wr16(r, o + 4, a);
        wr16(r, o + 6, b);
    } else {
        wr16(r, o, a);
        wr16(r, o + 2, b);
        var k: u32 = 0;
        while (k <= n) : (k += 1) {
            if (bit(fmask, k)) place(k, sx[k] +% ddx, sy[k] +% ddy);
        }
    }
    app.dirty = true;
}

fn frameRename() void {
    var f = Fmt{};
    f.str("node.frame_title ");
    f.uint(fsel);
    f.ch(' ');
    @import("editors.zig").prefillConsole(f.s());
}

fn frameDelete() void {
    undo.label("Comment Frame");
    const r = own() orelse return;
    const o = NE_FRAMES + @as(usize, fsel - 1) * FR_SZ;
    @memset(r[o .. o + FR_SZ], 0);
    fsel = 0;
    app.dirty = true;
}

// --- the add menu and the palette: entries ------------------------------------------

/// Shortcuts in the add menu: a type with its first value set (math and vector
/// math operations): type, value, category, title.
const Alias = struct { t: u8, v: u8, c: u8, title: []const u8 };
const aliases = [_]Alias{
    .{ .t = 7, .v = 0, .c = 2, .title = "Add" },          .{ .t = 7, .v = 1, .c = 2, .title = "Subtract" },
    .{ .t = 7, .v = 2, .c = 2, .title = "Multiply" },     .{ .t = 7, .v = 3, .c = 2, .title = "Divide" },
    .{ .t = 7, .v = 4, .c = 2, .title = "Power" },        .{ .t = 7, .v = 21, .c = 2, .title = "Lerp" },
    .{ .t = 7, .v = 20, .c = 2, .title = "Clamp" },       .{ .t = 7, .v = 19, .c = 2, .title = "Saturate" },
    .{ .t = 7, .v = 18, .c = 2, .title = "One Minus" },   .{ .t = 7, .v = 5, .c = 2, .title = "Min" },
    .{ .t = 7, .v = 6, .c = 2, .title = "Max" },          .{ .t = 7, .v = 9, .c = 2, .title = "Abs" },
    .{ .t = 7, .v = 8, .c = 2, .title = "Sine" },         .{ .t = 7, .v = 15, .c = 2, .title = "Fraction" },
    .{ .t = 7, .v = 22, .c = 2, .title = "Step" },        .{ .t = 7, .v = 23, .c = 2, .title = "Smoothstep" },
    .{ .t = 19, .v = 10, .c = 3, .title = "Dot Product" }, .{ .t = 19, .v = 11, .c = 3, .title = "Cross Product" },
    .{ .t = 19, .v = 12, .c = 3, .title = "Normalize" },  .{ .t = 19, .v = 13, .c = 3, .title = "Length" },
};

/// ne_entries: a material's types and shortcuts by category; a tree's types in order.
fn entries() void {
    var c: u32 = 0;
    const nt_ = ntypes();
    if (kind != 0) {
        var t: u32 = 1;
        while (t <= nt_) : (t += 1) {
            etit[c] = title(t);
            ent[c] = t;
            ecat[c] = 0;
            c += 1;
        }
        ne = c;
        return;
    }
    var k: u8 = 0;
    while (k < 7) : (k += 1) {
        var rank: u8 = 0;
        var t: u32 = 1;
        while (t <= nt_) : (t += 1) {
            if (sn.metas[t - 1].cat != k) continue;
            etit[c] = title(t);
            ent[c] = t;
            ecat[c] = k;
            erank[c] = rank;
            rank += 1;
            c += 1;
        }
        for (aliases) |a| {
            if (a.c != k) continue;
            ent[c] = a.t | (@as(u32, a.v) + 1) << 8;
            etit[c] = a.title;
            ecat[c] = k;
            erank[c] = rank;
            rank += 1;
            c += 1;
        }
    }
    ne = c;
}

/// vis_match: the text starts somewhere in the entry's title (any case).
fn visMatch(e: u32, s: []const u8) bool {
    const t = etit[e];
    var st: usize = 0;
    while (true) {
        var i: usize = 0;
        while (true) {
            if (i >= s.len) return true;
            if (st + i >= t.len) return false;
            if ((s[i] | 0x20) != (t[st + i] | 0x20)) break;
            i += 1;
        }
        st += 1;
        if (st >= t.len) return false;
    }
}

fn vis(e: u32) bool {
    if (fnl == 0) return true;
    return visMatch(e, filt[0..fnl]);
}
fn palVis(e: u32) bool {
    if (pfilt_len == 0) return true;
    return visMatch(e, pfilt[0..pfilt_len]);
}

fn vcount() u32 {
    var c: u32 = 0;
    var e: u32 = 0;
    while (e < ne) : (e += 1) {
        if (vis(e)) c += 1;
    }
    return c;
}

/// ne_nth: the k-th entry shown + 1 (0: none).
fn nth(k0: u32) u32 {
    var k = k0;
    var e: u32 = 0;
    while (e < ne) : (e += 1) {
        if (vis(e)) {
            k -%= 1;
            if (k == 0) return e + 1;
        }
    }
    return 0;
}

fn catmode() bool {
    ecat_on = kind == 0 and fnl == 0;
    return ecat_on;
}

/// ne_menu_size: rows (below its title) and columns.
fn menuSize() [2]i32 {
    if (catmode()) {
        var m: i32 = 0;
        for (erank[0..ne]) |x| m = @max(m, x);
        return .{ m + 2, 7 };
    }
    const c: i32 = @intCast(vcount());
    const cols = @divTrunc(c + MROWS - 1, MROWS);
    return .{ @min(c, MROWS), cols };
}

/// ne_mslot: the k-th entry shown: its column and row (1: the first below the title).
fn mslot(k: u32) [2]i32 {
    if (ecat_on) return .{ ecat[k - 1], @as(i32, erank[k - 1]) + 2 };
    return .{ @intCast((k - 1) / MROWS), @intCast((k - 1) % MROWS + 1) };
}

/// ne_menu_item: the entry under the pointer + 1 (0: none).
fn menuItem() u32 {
    _ = catmode();
    const a = ui.mx - mx;
    if (a < 0) return 0;
    const col: i32 = @divTrunc(a, MENU_W);
    const b = ui.my - my - 2;
    if (b < 0) return 0;
    const rw: i32 = @divTrunc(b, NROW);
    if (rw == 0) return 0;
    var c = vcount();
    while (c != 0) : (c -= 1) {
        const s = mslot(c);
        if (s[0] == col and s[1] == rw) return nth(c);
    }
    return 0;
}

fn drawMenu() void {
    const cv = &cv_shim;
    const th = ui.th;
    const sz = menuSize();
    const rws = sz[0];
    const cols = sz[1];
    cv.fill(.{ .x = mx - 1, .y = my - 1, .w = cols * MENU_W + 2, .h = (rws + 1) * NROW + 6 }, th.drop_border);
    cv.fill(.{ .x = mx, .y = my, .w = cols * MENU_W, .h = (rws + 1) * NROW + 4 }, th.drop_bg);
    _ = text(mx + 8, my + 3, if (fnl != 0) filt[0..fnl] else "Add node", th.text_dim);
    ui.record("addmenu", if (fnl != 0) filt[0..fnl] else "Add node", .{ .x = mx, .y = my, .w = cols * MENU_W, .h = (rws + 1) * NROW + 4 }, true);
    if (ecat_on) {
        for (0..7) |k| _ = text(@as(i32, @intCast(k)) * MENU_W + mx + 8, my + NROW + 4, sn.cat_names[k], th.accent);
    }
    const hot = menuItem();
    const vc = vcount();
    var k: u32 = 1;
    while (k <= vc) : (k += 1) {
        const s = mslot(k);
        const x = s[0] * MENU_W + mx;
        const y = s[1] * NROW + my + 2;
        const e = nth(k);
        if (e == hot) cv.fill(.{ .x = x, .y = y, .w = MENU_W, .h = NROW }, th.hover);
        _ = text(x + 12, y + 2, etit[e - 1], th.text);
        ui.record("addnode", etit[e - 1], .{ .x = x, .y = y, .w = MENU_W, .h = NROW }, true);
    }
}

/// do_ne_add_menu: the menu at the pointer (all of it inside the body).
fn openMenu() void {
    _ = rec() orelse return;
    entries();
    fnl = 0;
    filt[0] = 0;
    menu = true;
    mx = ui.mx;
    ax = ui.mx;
    ay = ui.my;
    const sz = menuSize();
    const h = (sz[0] + 1) * NROW + 6;
    var y = @min(ui.my, by + bh - h);
    if (y < by) y = by;
    my = y;
    app.dirty = true;
}

fn palOn() bool {
    return pal and ew >= PAL_W + 200 and bx != px;
}

/// pal_row: row k of the palette's list: 1 a category's name (c), 2 an entry (c).
fn palRow(k0: i32) ?[2]u32 {
    var k = k0;
    var shown: i32 = -1;
    var e: u32 = 0;
    while (e < ne) : (e += 1) {
        if (!palVis(e)) continue;
        if (kind == 0 and @as(i32, ecat[e]) != shown) {
            shown = ecat[e];
            if (k == 0) return .{ 1, ecat[e] };
            k -= 1;
        }
        if (k == 0) return .{ 2, e };
        k -= 1;
    }
    return null;
}

fn palHit(y: i32) u32 {
    const b = y - by - PAL_TOP;
    if (b < 0) return 0;
    entries();
    const rr = palRow(@divTrunc(b, NROW) + pscroll) orelse return 0;
    if (rr[0] != 2) return 0;
    return rr[1] + 1;
}

const PFILT_ID: u32 = 0x9e7f11;

fn drawPalette() void {
    if (!palOn()) return;
    const cv = &cv_shim;
    const th = ui.th;
    cv.fill(.{ .x = px, .y = by, .w = PAL_W, .h = bh }, COL_NE_PAL);
    paletteField();
    entries();
    var y = by + PAL_TOP;
    var k: i32 = 0;
    while (y + NROW <= by + bh) : ({
        y += NROW;
        k += 1;
    }) {
        const rr = palRow(k + pscroll) orelse break;
        if (rr[0] == 1) {
            _ = text(px + 10, y + 2, sn.cat_names[rr[1]], th.accent);
            continue;
        }
        const a = ui.mx - px;
        const b = ui.my - y;
        if (a >= 0 and a < PAL_W and b >= 0 and b < NROW) cv.fill(.{ .x = px, .y = y, .w = PAL_W, .h = NROW }, th.hover);
        _ = text(px + 20, y + 2, etit[rr[1]], th.text);
        ui.record("palette", etit[rr[1]], .{ .x = px, .y = y, .w = PAL_W, .h = NROW }, true);
    }
    if (drag == 13) _ = text(ui.mx + 12, ui.my + 4, etit[pdent], th.accent);
}

/// The palette's search (Enter): the text, the list back at its top.
fn paletteField() void {
    const r = Rect{ .x = px + 6, .y = by + 6, .w = PAL_W - 12, .h = 22 };
    Z.beginAt("##palette search", host.zr(r));
    const f = Z.textInput("##palette", &pfilt_edit, &pfilt_edit_len, .{ .width = .fill, .hint = "Search nodes" });
    Z.endAt();
    if (f.submitted or f.committed) {
        pfilt_len = @min(pfilt_edit_len, 31);
        @memcpy(pfilt[0..pfilt_len], pfilt_edit[0..pfilt_len]);
        pscroll = 0;
        app.dirty = true;
    }
}

var pfilt_edit: [31]u8 = undefined;
var pfilt_edit_len: usize = 0;

// --- the area -----------------------------------------------------------------------

fn canvasId() u32 {
    return ui.id(@src(), 0x4e45);
}

/// ed_nodes_draw and the input of the area body (r: below its header).
pub fn body(i: i16, r: Rect) void {
    area_i = i;
    ex = r.x;
    ey = r.y;
    ew = r.w;
    eh = r.h;
    bx = ex;
    by = ey + NE_BAR;
    bw = ew;
    bh = eh - NE_BAR;
    px = ex;
    if (pal and ew >= PAL_W + 200) {
        bx += PAL_W;
        bw -= PAL_W;
    }
    Z = host.beginPart("nodes", @intCast(i), r) orelse return;
    defer host.endPart(Z);
    zoomApply();
    // the pointer first, on the layout as it is, then the drawing
    if (rec()) |rr| layout(rr) else n = 0;
    input(r);
    draw();
    if (palOn()) paletteField();
}

fn draw() void {
    const cv = &cv_shim;
    const th = ui.th;
    cv.fill(.{ .x = ex, .y = ey, .w = ew, .h = eh }, COL_NE_BG);
    // a dot grid
    {
        const c0 = @rem(panx, grid) + grid;
        const r0 = @rem(pany, grid) + grid;
        var a = c0;
        while (a < bw) : (a += grid) {
            var b = r0;
            while (b < bh) : (b += grid) cv.fill(.{ .x = bx + a, .y = by + b, .w = 2, .h = 2 }, COL_NE_GRID);
        }
    }
    var r = rec() orelse {
        _ = text(ex + 8, ey + 3, s_ne_none, th.text_dim);
        n = 0;
        return;
    };
    if (fitpend != 0) {
        const m = fitpend - 1;
        fitpend = 0;
        frameView(m);
        r = rec() orelse return;
    }
    makeThumbs(r);
    layout(r);
    {
        const old = gfx.useFace(.node);
        defer _ = gfx.useFace(old);
        drawFrames(r);
        // wires: node inputs, then the material sockets
        var k: u32 = 1;
        while (k <= n) : (k += 1) {
            const ni = counts(typeOf(r, k))[0];
            var i: u32 = 0;
            while (i < ni) : (i += 1) {
                const l = rd(r, nodeOff(k) + ND_IN + i * 16);
                const from = l & 0xffff;
                const out = (l >> 16) & 0xff;
                if (from == 0 or from > n) continue;
                const a = outXY(from, out);
                const b = inXY(r, k, i);
                wire(a[0], a[1], b[0], b[1], wireCol(r, from, out, k));
            }
        }
        if (kind == 0) {
            var p: u32 = 0;
            while (p < NPINS) : (p += 1) {
                const l = rd(r, GR_PINS + p * 4);
                const from = l & 0xffff;
                if (from == 0 or from > n) continue;
                const out = l >> 16;
                const a = outXY(from, out);
                const b = inXY(r, 0, p);
                wire(a[0], a[1], b[0], b[1], wireCol(r, from, out, 0));
            }
        }
        k = 1;
        while (k <= n) : (k += 1) drawNode(r, k);
        if (kind == 0 and rd(r, MA_FUNC) != 1) drawOutput(r);
        drawMinimap(r);
        drawPane(r);
        drawStats(r);
        // a wire being dragged
        if (drag == 2) {
            const a = outXY(dn, dk);
            wire(a[0], a[1], ui.mx, ui.my, th.accent);
        } else if (drag == 3 or drag == 4) {
            const b = inXY(r, if (drag == 4) 0 else dn, dk);
            wire(ui.mx, ui.my, b[0], b[1], th.accent);
        }
    }
    drawPalette();
    if (drag == 9) cv.line(x0, y0, ui.mx, ui.my, COL_NE_KNIFE);
    if (drag == 8) drawBox();
    // the title line over the canvas: the material or tree, the keys
    cv.fill(.{ .x = ex, .y = ey, .w = ew, .h = NE_BAR }, COL_NE_BG);
    var head: []const u8 = "Material: ";
    if (kind == 0) {
        if (rd(r, MA_FUNC) == 1) head = "Function: ";
    } else if (kind == 2) {
        head = "Logic: ";
    } else head = if (pathn != 0) "Group: " else "Geometry: ";
    var pen = text(ex + 8, ey + 3, head, th.text_dim);
    pen = text(pen, ey + 3, std.mem.sliceTo(r[0..32], 0), th.text);
    const keys = switch (kind) {
        0 => s_ne_keys,
        2 => s_ne_lkeys,
        else => if (pathn != 0) s_ne_grkeys else s_ne_gkeys,
    };
    pen = text(pen, ey + 3, keys, th.text_dim);
    if (kind == 0 and pref != 0) _ = text(pen, ey + 3, "  Tab geometry", th.text_dim);
    if (menu) drawMenu();
}

// --- hits ---------------------------------------------------------------------------

const Hit = struct { what: u32 = 0, node: u32 = 0, k: u32 = 0 };

fn near(p: [2]i32, x: i32, y: i32) bool {
    const a = p[0] -% x;
    const b = p[1] -% y;
    return a >= -7 and a <= 7 and b >= -7 and b <= 7;
}

fn inBox(k: u32, x: i32, y: i32) bool {
    const a = x -% lx[k];
    if (a < 0 or a >= wof(k)) return false;
    const b = y -% ly[k];
    return b >= 0 and b < lh[k];
}

/// ne_hit: 0 none, 1 a node's header, 2 its output k, 3 its input socket k, 4 a
/// material socket k, 5 its value k, 6 its input row k, 7 its body (node 0: the output).
fn hitAt(x: i32, y: i32) Hit {
    const r = rec() orelse return .{};
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        const t = typeOf(r, k);
        const no = nouts(t);
        var i: u32 = 0;
        while (i < no) : (i += 1) {
            if (near(outXY(k, i), x, y)) return .{ .what = 2, .node = k, .k = i };
        }
        const ni = counts(t)[0];
        i = 0;
        while (i < ni) : (i += 1) {
            if (near(inXY(r, k, i), x, y)) return .{ .what = 3, .node = k, .k = i };
        }
    }
    if (kind == 0) {
        var p: u32 = 0;
        while (p < NPINS) : (p += 1) {
            if (near(inXY(r, 0, p), x, y)) return .{ .what = 4, .node = 0, .k = p };
        }
    }
    var b: u32 = 0;
    var found = inBox(0, x, y);
    if (!found) {
        b = n;
        while (b != 0) : (b -= 1) {
            if (inBox(b, x, y)) {
                found = true;
                break;
            }
        }
        if (!found) return .{};
    }
    const rel = y -% ly[b];
    if (rel < hdr) return .{ .what = 1, .node = b };
    if (b == 0) return .{ .what = 7, .node = 0 };
    const rw: u32 = @intCast(@divTrunc(rel - hdr, row));
    const t = typeOf(r, b);
    const no = nouts(t);
    if (rw < no) return .{ .what = 7, .node = b };
    const c = counts(t);
    const v = rw - no;
    if (v < c[1]) return .{ .what = 5, .node = b, .k = v };
    if (v - c[1] < c[0]) return .{ .what = 6, .node = b, .k = v - c[1] };
    return .{ .what = 7, .node = b };
}

// --- running operators as the original does (ne_run) --------------------------------

fn runOp(id: []const u8, a: []const u8) void {
    const i = ops.byId(id) orelse return;
    const keep = ops.arg;
    ops.arg = a;
    defer ops.arg = keep;
    // (the original's run_op pushes an undo step before each of these: what came
    // before in this input is a step of its own)
    undo.sync();
    ops.run(i);
}

/// ne_arg_start: the record's name and a space.
fn argStart(f: *Fmt) void {
    if (rec()) |r| f.str(std.mem.sliceTo(r[0..32], 0));
    f.ch(' ');
}
fn argInt(f: *Fmt, v: u32) void {
    f.uint(v);
    f.ch(' ');
}
/// ne_arg_done: (the original's 128-byte argument buffer)
fn argDone(f: *const Fmt) []const u8 {
    return f.b[0..@min(f.l, 127)];
}

/// ne_link: material.link / tree.link (a loop: it says so, does nothing).
fn link(from: u32, to: u32, inp: u32, out: u32) void {
    if (from == to) return;
    var f = Fmt{};
    argStart(&f);
    f.uint(from);
    if (kind != 0) {
        f.ch(':');
        f.uint(out);
    }
    f.ch(' ');
    argInt(&f, to);
    argInt(&f, inp + 1);
    if (kind == 0 and out != 0) argInt(&f, out);
    runOp(if (kind == 0) "material.link" else "tree.link", argDone(&f));
}

/// ne_socket: material.socket.
fn socket(node: u32, pin: u32, out: u32) void {
    var f = Fmt{};
    argStart(&f);
    f.str(gops.socket_names[pin]);
    f.ch(' ');
    argInt(&f, node);
    if (out != 0) argInt(&f, out);
    runOp("material.socket", argDone(&f));
}

/// ne_unlink: through node_set (its constant again: unlinked).
fn unlink(node: u32, k: u32, cst: [3]f32) void {
    var f = Fmt{};
    argStart(&f);
    argInt(&f, node);
    argInt(&f, k + 1);
    for (cst) |v| {
        f.num4(v);
        f.ch(' ');
    }
    runOp(if (kind == 0) "material.node_set" else "tree.node_set", argDone(&f));
}

/// ne_add_node(entry + 1): material.node / tree.node / logic.node, placed where
/// the menu was, then the wire that opened the menu linked to it.
fn addNode(e: u32) void {
    const v = ent[e - 1];
    const t = v & 0xff;
    const r = rec() orelse return;
    const c = rd(r, GR_N);
    if (c >= maxn) {
        app.log("  node editor: the graph is full (12 shader nodes, 48 in a tree)", .{});
        return;
    }
    var f = Fmt{};
    argStart(&f);
    f.str(switch (kind) {
        0 => gops.type_names[t - 1],
        1 => gn.type_names[t - 1],
        else => logic.type_names[t - 1],
    });
    if (kind == 0 and t == 1 and images.count != 0) {
        f.ch(' ');
        f.str(images.nameOf(0));
    }
    if (v >> 8 != 0) {
        f.ch(' ');
        f.uint((v >> 8) - 1);
    }
    runOp(switch (kind) {
        0 => "material.node",
        1 => "tree.node",
        else => "logic.node",
    }, argDone(&f));
    const r2_ = rec() orelse return;
    if (rd(r2_, GR_N) <= c) return;
    const k = c + 1;
    sel = k;
    selm = bitOf(k);
    place(k, unzoom(ax - bx - panx), unzoom(ay - by - pany));
    pendLink(k);
}

/// ne_pend_link: the wire that opened the menu linked to the node just added
/// (into its first input of the wire's kind, else its first; out of its first output).
fn pendLink(k: u32) void {
    const p = pend;
    pend = 0;
    if (p == 0) return;
    const r = rec() orelse return;
    if (p == 1) {
        const m = metaOf(typeOf(r, k)) orelse return;
        if (m.in[0] == null) return;
        const wkind = if (metaOf(typeOf(r, pnode))) |pm| (if (pk < 8) pm.ok[pk] else 0) else 0;
        var i: u32 = 0;
        var found: u32 = 0;
        while (i < 3) : (i += 1) {
            if (m.in[i] == null) break;
            if (m.ik[i] == wkind) {
                found = i;
                break;
            }
        }
        link(pnode, k, found, pk);
    } else if (p == 2) {
        link(k, pnode, pk, 0);
    } else socket(k, pk, 0);
}

// --- input ---------------------------------------------------------------------------

var drag_area: i16 = -1;

var in_mx: i32 = 0;
var in_my: i32 = 0;
/// The canvas holds the pointer (a press on it, until it is let go).
var holding: u8 = 0;

/// The pointer over the body, once a frame from Zui's input: a press
/// (left or middle; right opens the node menu), its drag, its release, the
/// wheel.
fn input(r: Rect) void {
    const in = &Z.input;
    const it = Z.interact(Z.id("##canvas"), host.zr(r));
    const moved = ui.mx != in_mx or ui.my != in_my;
    in_mx = ui.mx;
    in_my = ui.my;
    const lp = it.pressed;
    const mp = it.hovered and in.mouse_pressed.contains(.middle);
    const rp = it.hovered and in.mouse_pressed.contains(.right);
    // (the palette's search: its own presses)
    const in_field = palOn() and (Rect{ .x = px + 6, .y = by + 6, .w = PAL_W - 12, .h = 22 }).contains(ui.mx, ui.my);
    // the add menu takes a press anywhere (a widget's aside)
    if (menu and (lp or mp or rp)) {
        menu = false;
        app.dirty = true;
        if (lp) {
            const e = menuItem();
            if (e != 0) addNode(e);
        }
        return;
    }
    if (menu and moved) app.dirty = true;
    if (drag != 0 and drag_area == area_i and holding != 0) {
        const still = if (holding == ui.MMB) in.mouse_down.contains(.middle) else it.held;
        if (still) {
            if (moved) motion(ui.mx, ui.my);
        } else {
            holding = 0;
            release();
        }
    } else if (drag != 0 and drag_area == area_i and holding == 0) {
        drag = 0; // (lost: the drag ended elsewhere)
    }
    if ((lp or mp or rp) and holding == 0 and !in_field) {
        app.dirty = true;
        if (rp) {
            // the node under it selected, then the menu
            const h = hitAt(ui.mx, ui.my);
            if (h.what != 0 and !bit(selm, h.node)) {
                selm = bitOf(h.node);
                sel = h.node;
            }
            menus.openAt(&ctx_nodes, ui.mx, ui.my, area_i);
            return;
        }
        drag_area = area_i;
        holding = if (mp) ui.MMB else ui.LMB;
        // (where it was pressed: a quick drag can come whole in one frame)
        const pp = in.press_pos.get(if (mp) .middle else .left);
        const px_: i32 = @intFromFloat(pp.x);
        const py_: i32 = @intFromFloat(pp.y);
        press(holding, px_, py_);
        if (drag == 0) {
            holding = 0;
        } else {
            const down = if (mp) in.mouse_down.contains(.middle) else in.mouse_down.contains(.left);
            if (ui.mx != px_ or ui.my != py_) motion(ui.mx, ui.my);
            if (!down) {
                // let go in the same frame
                holding = 0;
                release();
            }
        }
    }
    if (it.hovered and in.scroll.y != 0 and holding == 0) {
        wheel(if (in.scroll.y < 0) -1 else 1);
    }
}

/// nodeed_press.
fn press(btn: u8, x: i32, y: i32) void {
    app.dirty = true;
    if (palOn() and x < bx) {
        // the palette: an entry to drag
        if (btn != ui.LMB) return;
        const e = palHit(y);
        if (e == 0) return;
        pdent = e - 1;
        drag = 13;
        x0 = x;
        y0 = y;
        return;
    }
    if (btn == ui.LMB and inPane(x, y)) {
        drag = 14;
        x0 = x;
        y0 = y;
        pa0 = .{ pyaw, ppitch };
        return;
    }
    if (btn == ui.LMB and inMinimap(x, y)) {
        drag = 12;
        minimapGo(x, y);
        return;
    }
    x0 = x;
    y0 = y;
    undone = false;
    pick = false;
    pend = 0;
    if (btn == ui.MMB) {
        sel = 0;
        selm = 0;
        drag = 7;
        a0 = @bitCast(panx);
        b0 = pany;
        return;
    }
    const h = hitAt(x, y);
    dn = h.node;
    dk = h.k;
    switch (h.what) {
        0 => return pressEmpty(x, y),
        2 => {
            drag = 2;
            return;
        },
        3 => {
            // an input: its link picked up
            const r = rec() orelse return;
            const io = nodeOff(dn) + ND_IN + dk * 16;
            const l = rd(r, io);
            if (l == 0) {
                drag = 3;
                return;
            }
            unlink(dn, dk, .{ rdf(r, io + 4), rdf(r, io + 8), rdf(r, io + 12) });
            undo.sync(); // (a step of its own, as the original's operator)
            dn = l & 0xffff;
            dk = (l >> 16) & 0xff;
            pick = true;
            drag = 2;
            return;
        },
        4 => {
            // a material socket: picked up too
            const r = rec() orelse return;
            const l = rd(r, GR_PINS + dk * 4);
            if (l & 0xffff == 0) {
                drag = 4;
                return;
            }
            var f = Fmt{};
            argStart(&f);
            f.str(gops.socket_names[dk]);
            f.str(" none");
            runOp("material.socket", argDone(&f));
            undo.sync();
            dn = l & 0xffff;
            dk = l >> 16;
            pick = true;
            drag = 2;
            return;
        },
        else => {},
    }
    // on a node: selected (Shift: added, or taken out again)
    sel = dn;
    if (ui.shift()) {
        selm ^= bitOf(dn);
    } else if (!bit(selm, dn)) selm = bitOf(dn);
    if (h.what == 5) {
        if (nameValue()) return;
        drag = 5;
        a0 = @bitCast(valuePtr().*);
        return;
    }
    if (h.what == 6 and inputEditable()) {
        drag = 6;
        a0 = @bitCast(valuePtr().*);
        return;
    }
    // the header or body: moved, with the rest of the selection
    drag = 1;
    var k: u32 = 0;
    while (k <= n) : (k += 1) {
        sx[k] = gx[k];
        sy[k] = gy[k];
    }
    a0 = @bitCast(gx[dn]);
    b0 = gy[dn];
}

fn pressEmpty(x: i32, y: i32) void {
    // a quick key armed: its node here
    if (arm) {
        arm = false;
        if (app.now_ms - armt <= 3000) {
            ax = x;
            ay = y;
            entries();
            ent[159] = armq;
            addNode(160);
            return;
        }
    }
    // Alt: a knife through wires (a click: the wire under it)
    if (ui.mods & @import("wayland.zig").MOD_ALT != 0) {
        drag = 9;
        return;
    }
    // a double-click on a wire: a reroute
    const now = app.now_ms;
    const dt = now - clkt;
    clkt = now;
    if (dt <= 400) {
        const a = x - clkx;
        const b = y - clky;
        if (a * a + b * b <= 36 and wireScan(0) != 0) {
            clkt = 0;
            reroute();
            return;
        }
    }
    clkx = x;
    clky = y;
    if (frameHit(x, y)) |fh| {
        fwas = fsel -% 1 == fh[1];
        fsel = fh[1] + 1;
        sel = 0;
        selm = 0;
        drag = if (fh[0] == 1) 10 else 11;
        dk = fh[1];
        frameGrab(fh[1]);
        return;
    }
    fsel = 0;
    drag = 8;
}

/// ne_name_value: a name (logic): the console gets "logic.name <graph> <node> <slot> ".
fn nameValue() bool {
    if (kind != 2) return false;
    const r = rec() orelse return false;
    const m = metaOf(typeOf(r, dn)) orelse return false;
    if (dk >= 4 or m.vk[dk] != 5) return false;
    var f = Fmt{};
    f.str("logic.name ");
    f.str(std.mem.sliceTo(r[0..32], 0));
    f.ch(' ');
    f.uint(dn);
    f.ch(' ');
    f.uint(dk + 4);
    f.ch(' ');
    @import("editors.zig").prefillConsole(f.s());
    return true;
}

/// ne_value_ptr: the float dragged (drag 5 a value, 6 an input's constant).
fn valuePtr() *const f32 {
    const r = rec().?;
    const o = nodeOff(dn);
    const at = if (drag == 6) o + ND_IN + dk * 16 + 4 else o + ND_P + dk * 4;
    return @ptrCast(@alignCast(&r[at]));
}

/// ne_input_editable: an unlinked number input.
fn inputEditable() bool {
    const r = rec() orelse return false;
    const o = nodeOff(dn);
    if (rd(r, o + ND_IN + dk * 16) != 0) return false;
    const m = metaOf(rd(r, o)) orelse return false;
    return m.ik[dk] == 1;
}

/// ne_first_change: the drag's undo step, once.
fn firstChange() void {
    if (undone) return;
    undone = true;
    undo.label(if (drag >= 10) "Comment Frame" else if (drag == 1) "Move Node" else "Change Node Value");
}

/// ne_new_value: the dragged value from a0 - numbers 0.01 a pixel, choices /
/// images / trees / whole numbers a step per 12 px.
fn newValue(ddx: i32) f32 {
    const v0: f32 = @bitCast(a0);
    var vk: u8 = 0;
    var m_: ?MV = null;
    if (drag != 6) {
        if (rec()) |r| {
            m_ = metaOf(typeOf(r, dn));
            if (m_) |m| vk = if (dk < 4) m.vk[dk] else 0;
        }
    }
    if (vk == 0) {
        var x = v0 + @as(f32, @floatFromInt(ddx)) * 0.01;
        x *= 100.0;
        x = roundEven(x);
        return x / 100.0;
    }
    var st = @divTrunc(ddx, 12) +% cvt(v0);
    var hi: i32 = 16;
    const m = m_.?;
    switch (vk) {
        6 => hi = @as(i32, @intCast(m.ch2.len)) - 1,
        1 => hi = @as(i32, @intCast(m.ch.len)) - 1,
        2 => hi = @intCast(images.count),
        4 => hi = @intCast(nt.count()),
        else => {
            if (st < 1) st = 1;
        },
    }
    if (st < 0) st = 0;
    if (st > hi) st = hi;
    return @floatFromInt(st);
}

fn roundEven(x: f32) f32 {
    if (!std.math.isFinite(x)) return x;
    if (@abs(x - @trunc(x)) == 0.5) return 2 * @round(x / 2);
    return @round(x);
}

/// nodeed_motion (a drag).
fn motion(x: i32, y: i32) void {
    app.dirty = true;
    switch (drag) {
        7 => {
            panx = x - x0 + @as(i32, @bitCast(a0));
            pany = y - y0 + b0;
        },
        14 => paneTurn(x, y),
        12 => minimapGo(x, y),
        10, 11 => frameDrag(x, y),
        1 => {
            firstChange();
            const ddx = unzoom(x - x0);
            const ddy = unzoom(y - y0);
            var k: u32 = 0;
            while (k <= n) : (k += 1) {
                if (bit(selm, k) or k == dn) place(k, sx[k] +% ddx, sy[k] +% ddy);
            }
        },
        5, 6 => {
            firstChange();
            const v = newValue(x - x0);
            const slot: u32 = if (drag == 6) dk + 1 else dk + 4;
            if (mat < 0) return;
            if (kind == 0) {
                _ = gops.setSlot(@intCast(mat), dn, slot, &.{v});
            } else _ = nt.set(@intCast(mat), @intCast(dn), @intCast(slot), &.{v});
        },
        else => {}, // (wires, the box, the knife, a palette entry: only drawn)
    }
}

/// ne_box_select: every node touching the box: the selection (Shift: added,
/// Ctrl: taken out); a click in empty space: nothing selected (Shift / Ctrl: kept).
fn boxSelect(x: i32, y: i32) void {
    var xa = x0;
    var xb = x;
    if (xa > xb) std.mem.swap(i32, &xa, &xb);
    var ya = y0;
    var yb = y;
    if (ya > yb) std.mem.swap(i32, &ya, &yb);
    const shift = ui.mods & @import("wayland.zig").MOD_SHIFT != 0;
    const ctrl = ui.mods & @import("wayland.zig").MOD_CTRL != 0;
    var m: u64 = if (shift or ctrl) selm else 0;
    var k: u32 = if (kind == 0) 0 else 1;
    while (k <= n) : (k += 1) {
        if (lx[k] > xb) continue;
        if (lx[k] +% wof(k) < xa) continue;
        if (ly[k] > yb) continue;
        if (ly[k] +% lh[k] < ya) continue;
        m |= bitOf(k);
        if (ctrl) m &= ~bitOf(k);
    }
    selm = m;
    sel = if (m == 0) 0 else @ctz(m);
    app.dirty = true;
}

/// nodeed_release: a wire dropped, a drag ended.
fn release() void {
    const d = drag;
    if (d == 0) return;
    drag = 0;
    app.dirty = true;
    const x = ui.mx;
    const y = ui.my;
    const dd = (x - x0) * (x - x0) + (y - y0) * (y - y0);
    switch (d) {
        2 => {
            // onto an input or a material socket (empty space: the add menu)
            const h = hitAt(x, y);
            switch (h.what) {
                0 => return menuFor(1, dd),
                3, 6 => link(dn, h.node, h.k, dk),
                4 => socket(dn, h.k, dk),
                else => {},
            }
        },
        3 => {
            const h = hitAt(x, y);
            if (h.what == 0) return menuFor(2, dd);
            if (h.what == 2) link(h.node, dn, dk, h.k);
        },
        4 => {
            const h = hitAt(x, y);
            if (h.what == 0) return menuFor(3, dd);
            if (h.what == 2) socket(h.node, dk, h.k);
        },
        8 => boxSelect(x, y),
        9 => {
            // wires cut: crossed, or (a click) the one under the pointer
            if (dd <= 36) {
                if (wireScan(0) == 0) return;
                cutl[0] = .{ wto, wk };
                ncut = 1;
                cutLinks();
            } else {
                _ = wireScan(1);
                cutLinks();
            }
        },
        13 => {
            // a palette entry dropped: its node at the drop (in the palette: in
            // the middle of the view)
            ax = x;
            ay = y;
            if (x < bx) {
                ax = (bw >> 1) + bx;
                ay = (bh >> 1) + by;
            }
            entries();
            addNode(pdent + 1);
        },
        14 => {
            // the pane clicked: the next shape
            if (dd > 9) return;
            pshape = (pshape + 1) % 3;
        },
        5, 6 => {
            // a value clicked twice, unchanged: typed in the console
            if (undone) return;
            const now = app.now_ms;
            const dt = now - vclkt;
            vclkt = now;
            const slot: u32 = (if (d == 5) dk + 3 else dk) + 1;
            if (dt <= 400 and dn == vclkn and slot == vclkk) {
                vclkt = 0;
                typeValue(slot);
                return;
            }
            vclkn = dn;
            vclkk = slot;
        },
        10 => {
            // a frame's title clicked again: rename
            if (undone or !fwas) return;
            frameRename();
        },
        else => {},
    }
}

/// .Lnr_menu: a wire dropped in empty space (not a link picked up, moved 8 px or
/// more): the add menu, the new node linked by it.
fn menuFor(kind_: u32, dd: i32) void {
    if (pick) return;
    if (dd < 64) return;
    openMenu();
    pend = kind_;
    pnode = dn;
    pk = dk;
}

/// ne_type_value: the console asks for it: "material.node_set <material> <node> <slot> ".
fn typeValue(slot: u32) void {
    var f = Fmt{};
    f.str(if (kind == 0) "material.node_set" else "tree.node_set");
    f.ch(' ');
    if (rec()) |r| f.str(std.mem.sliceTo(r[0..32], 0));
    f.ch(' ');
    f.uint(dn);
    f.ch(' ');
    f.uint(slot);
    f.ch(' ');
    @import("editors.zig").prefillConsole(f.s());
}

/// nodeed_wheel: the palette scrolls 3 rows a notch; Ctrl scrolls, Shift sideways;
/// else a zoom step about the pointer.
fn wheel(steps: i32) void {
    app.dirty = true;
    if (palOn() and ui.mx < bx) {
        pscroll -= steps * 3;
        if (pscroll < 0) pscroll = 0;
        return;
    }
    const W = @import("wayland.zig");
    if (ui.mods & W.MOD_CTRL != 0) {
        pany += steps * 40;
        return;
    }
    if (ui.mods & W.MOD_SHIFT != 0) {
        panx += steps * 40;
        return;
    }
    var i: usize = 0;
    var z = zsteps[0];
    while (true) {
        z = zsteps[i];
        if (z >= zoom) break;
        i += 1;
        if (i >= zsteps.len - 1) {
            z = zsteps[i];
            break;
        }
    }
    if (steps < 0) {
        if (i == 0) return;
        i -= 1;
    } else if (z == zoom) {
        i += 1;
        if (i >= zsteps.len) return;
    }
    zoomAt(zsteps[i], ui.mx, ui.my);
}

/// ne_zoom_at: the zoom (%), the screen point that stays put.
fn zoomAt(z: i32, x: i32, y: i32) void {
    const a = x - bx;
    panx = a - @divTrunc((a - panx) *% z, zoom);
    const b = y - by;
    pany = b - @divTrunc((b - pany) *% z, zoom);
    zoom = z;
    zoomApply();
    app.dirty = true;
}

/// nodeed_key: the open menu takes every key (Esc closes it, Backspace, Enter
/// adds the first one shown, letters search).
pub fn key(raw: u32) void {
    app.dirty = true;
    const K = ui.KEY;
    if (raw == K.ESC) {
        menu = false;
        return;
    }
    if (raw == K.BACKSPACE) {
        if (fnl == 0) return;
        fnl -= 1;
        filt[fnl] = 0;
        return;
    }
    if (raw == K.ENTER) {
        const e = nth(1);
        menu = false;
        if (e != 0) addNode(e);
        return;
    }
    const c = @import("keyboard.zig").char(raw, ui.mods);
    if (c < ' ' or c >= 127) return;
    if (fnl >= 30) return;
    filt[fnl] = @intCast(c);
    filt[fnl + 1] = 0;
    fnl += 1;
}

// --- operators ----------------------------------------------------------------------

/// do_ne_add_menu.
fn opAddMenu() void {
    openMenu();
}

/// do_ne_delete: the selection (a comment frame selected: it alone), last first.
fn opDelete() void {
    if (fsel != 0) return frameDelete();
    var m = selm;
    if (m == 0) {
        if (sel == 0) return;
        m = bitOf(sel);
    }
    if (rec() != null) {
        undo.label("Delete Nodes");
        while (m != 0) {
            const k: u32 = 63 - @clz(m);
            m &= ~bitOf(k);
            if (k == 0) break;
            const r = rec() orelse break;
            if (k > rd(r, GR_N)) continue;
            if (mat < 0) break;
            if (kind == 0) {
                _ = gops.delete(@intCast(mat), k);
            } else _ = nt.delete(@intCast(mat), @intCast(k));
        }
    }
    sel = 0;
    selm = 0;
    app.dirty = true;
}

/// ne_copy: the selection into the node clipboard, links between them marked
/// (bit 30: the clipboard's own numbering); the count.
fn copyNodes() u32 {
    const r = rec() orelse return 0;
    layout(r);
    cmap = @splat(0);
    var m = selm;
    if (m == 0) {
        if (sel == 0) return 0;
        m = bitOf(sel);
    }
    var c: u32 = 0;
    clipx0 = std.math.maxInt(i32);
    clipy0 = std.math.maxInt(i32);
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        if (!bit(m, k)) continue;
        const o = nodeOff(k);
        @memcpy(clipnodes[c * NODE_SZ ..][0..NODE_SZ], r[o .. o + NODE_SZ]);
        clippos[c] = .{ gx[k], gy[k] };
        clipx0 = @min(clipx0, gx[k]);
        clipy0 = @min(clipy0, gy[k]);
        c += 1;
        cmap[k] = c;
    }
    if (c == 0) return 0;
    var i: u32 = 0;
    while (i < c) : (i += 1) {
        for (0..3) |q| {
            const at = i * NODE_SZ + ND_IN + q * 16;
            const l = std.mem.readInt(u16, clipnodes[at..][0..2], .little);
            if (l == 0 or l > 48) continue;
            const nk = cmap[l];
            if (nk == 0) continue;
            std.mem.writeInt(u16, clipnodes[at..][0..2], @intCast(nk), .little);
            const d = std.mem.readInt(u32, clipnodes[at..][0..4], .little);
            std.mem.writeInt(u32, clipnodes[at..][0..4], d | 0x40000000, .little);
        }
    }
    clipn = c;
    clipk = kind;
    clipm = mat;
    return c;
}

/// ne_paste: the clipboard appended with its top left at (x, y) (links among them
/// renumbered; links from outside kept in the graph they came from, else the
/// input's constant); they become the selection.
fn pasteNodes(x: i32, y: i32, what: []const u8) u32 {
    _ = rec() orelse return 0;
    const c = clipn;
    if (c == 0) return 0;
    if (kind != clipk) {
        app.log("  the clipboard holds nodes of another kind", .{});
        return 0;
    }
    undo.label(what);
    const rw = own() orelse return 0;
    const base = rd(rw, GR_N);
    if (base + c > maxn) {
        app.log("  not enough room: a graph holds 48 nodes", .{});
        return 0;
    }
    const same = mat == clipm;
    var i: u32 = 0;
    while (i < c) : (i += 1) {
        const o = nodeOff(base + i + 1);
        @memcpy(rw[o .. o + NODE_SZ], clipnodes[i * NODE_SZ ..][0..NODE_SZ]);
        for (0..3) |q| {
            const at = o + ND_IN + q * 16;
            const l = rd(rw, at);
            if (l & 0xffff == 0) continue;
            if (l & 0x40000000 != 0) {
                wr32(rw, at, (l & 0x00ff0000) | ((l & 0xffff) + base));
            } else if (!(same and (l & 0xffff) <= base)) wr32(rw, at, 0);
        }
        const nx = clippos[i][0] -% clipx0 +% x;
        var ny = clippos[i][1] -% clipy0 +% y;
        if (nx | ny == 0) ny += 1; // ((0, 0): not placed)
        wr16(rw, o + ND_POS, nx);
        wr16(rw, o + ND_POS + 2, ny);
    }
    wr32(rw, GR_N, base + c);
    var m: u64 = 0;
    i = 0;
    while (i < c) : (i += 1) m |= bitOf(base + i + 1);
    selm = m;
    sel = base + 1;
    app.dirty = true;
    return c;
}

fn opCopy() void {
    const c = copyNodes();
    if (c != 0) app.log("  nodes copied: {d}", .{c});
}

/// node.paste: at the pointer (outside the body: its top left).
fn opPaste() void {
    var a = ui.mx - bx;
    var b = ui.my - by;
    if (a < 0 or a >= bw or b < 0 or b >= bh) {
        a = 40;
        b = 40;
    }
    _ = pasteNodes(unzoom(a - panx), unzoom(b - pany), "Paste Nodes");
}

/// node.duplicate: copies of the selection, 40 down and right (the clipboard as it was).
fn opDup() void {
    const keep_k = clipk;
    const keep_n = clipn;
    const keep_m = clipm;
    const keep_x = clipx0;
    const keep_y = clipy0;
    const keep_nodes = clipnodes;
    const keep_pos = clippos;
    if (copyNodes() != 0) _ = pasteNodes(clipx0 +% 40, clipy0 +% 40, "Duplicate Nodes");
    clipk = keep_k;
    clipn = keep_n;
    clipm = keep_m;
    clipx0 = keep_x;
    clipy0 = keep_y;
    clipnodes = keep_nodes;
    clippos = keep_pos;
}

fn opCut() void {
    if (copyNodes() != 0) opDelete();
}

/// node.collapse (H): the selection collapsed, or (all of it collapsed already)
/// whole again.
fn opCollapse() void {
    const m = selm & ~@as(u64, 1);
    if (m == 0) return;
    const r = rec() orelse return;
    var all = true;
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        if (bit(m, k) and nflag(r, k) & 1 == 0) all = false;
    }
    undo.label("Collapse Nodes");
    const rw = own() orelse return;
    k = 1;
    while (k <= n) : (k += 1) {
        if (!bit(m, k)) continue;
        rw[NE_NFLAGS + k - 1] &= 0xfe;
        if (!all) rw[NE_NFLAGS + k - 1] |= 1;
    }
    app.dirty = true;
}

/// node.comment (C): a frame around the selection (none: at the pointer,
/// 320 x 200); it becomes the selected one.
fn opComment() void {
    const r = rec() orelse return;
    layout(r);
    var slot: u32 = 0;
    while (rd16(r, NE_FRAMES + @as(usize, slot) * FR_SZ + 4) > 0) {
        slot += 1;
        if (slot >= NE_NFR) {
            app.log("  a graph holds 6 comment frames", .{});
            return;
        }
    }
    var xa: i32 = std.math.maxInt(i32);
    var ya: i32 = std.math.maxInt(i32);
    var xb: i32 = std.math.minInt(i32);
    var yb: i32 = std.math.minInt(i32);
    var k: u32 = 0;
    while (k <= n) : (k += 1) {
        if (!bit(selm, k)) continue;
        xa = @min(xa, gx[k]);
        xb = @max(xb, addgw(gx[k], k));
        ya = @min(ya, gy[k]);
        yb = @max(yb, gy[k] +% gh[k]);
    }
    if (xa > xb) {
        xa = unzoom(ui.mx - bx - panx);
        xb = xa + 320;
        ya = unzoom(ui.my - by - pany);
        yb = ya + 200;
    } else {
        xa -= 20;
        ya -= NHDR + 24;
        xb += 20;
        yb += 20;
    }
    undo.label("Comment Frame");
    const rw = own() orelse return;
    const o = NE_FRAMES + @as(usize, slot) * FR_SZ;
    wr16(rw, o, xa);
    wr16(rw, o + 2, ya);
    wr16(rw, o + 4, xb -% xa);
    wr16(rw, o + 6, yb -% ya);
    wr32(rw, o + 8, 0);
    @memcpy(rw[o + 12 .. o + 20], "Comment\x00");
    fsel = slot + 1;
    app.dirty = true;
}

/// node.frame_title <frame 1-6> <title>
fn opFrameTitle() void {
    const a = ops.arg;
    var e: usize = 0;
    const v = nt.parseFloat(a, &e) orelse return frameNeed();
    const f = cvtt(v) -% 1;
    if (f < 0 or f >= NE_NFR) return frameNeed();
    var s = a[e..];
    while (s.len > 0 and s[0] == ' ') s = s[1..];
    const rw = own() orelse return frameNeed();
    const o = NE_FRAMES + @as(usize, @intCast(f)) * FR_SZ;
    if (rd16(rw, o + 4) <= 0) return frameNeed();
    const l = @min(s.len, 35);
    @memcpy(rw[o + 12 .. o + 12 + l], s[0..l]);
    rw[o + 12 + l] = 0;
    app.dirty = true;
}
fn frameNeed() void {
    app.log("  node.frame_title <frame 1-6> <title>", .{});
}

/// ne_align(0 left edges, 1 tops, 2 spread along x, 3 along y): the selected
/// nodes (2 or more; spreading: 3 or more).
fn alignNodes(mode: u32) void {
    const r = rec() orelse return;
    layout(r);
    var m = selm;
    if (kind != 0) m &= ~@as(u64, 1);
    const c: u32 = @popCount(m);
    if (c < 2) return;
    if (mode >= 2 and c < 3) return;
    const axis = if (mode & 1 != 0) &gy else &gx;
    var order: [49]u32 = undefined;
    var cnt: u32 = 0;
    var k: u32 = 0;
    while (k <= n) : (k += 1) {
        if (!bit(m, k)) continue;
        var j = cnt;
        while (j > 0 and axis[order[j - 1]] > axis[k]) : (j -= 1) order[j] = order[j - 1];
        order[j] = k;
        cnt += 1;
    }
    undo.label("Align Nodes");
    const first = axis[order[0]];
    const last = axis[order[cnt - 1]];
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        var v = first;
        if (mode >= 2) v = @divTrunc((last -% first) *% @as(i32, @intCast(i)), @as(i32, @intCast(cnt - 1))) +% first;
        const nd = order[i];
        if (mode & 1 == 0) place(nd, v, gy[nd]) else place(nd, gx[nd], v);
    }
    app.dirty = true;
}

fn opAlignL() void {
    alignNodes(0);
}
fn opAlignT() void {
    alignNodes(1);
}
fn opDistX() void {
    alignNodes(2);
}
fn opDistY() void {
    alignNodes(3);
}

/// node.quick_* (as in Unreal): the next click on the canvas (within 3 s) adds
/// that node there (materials only).
fn armFn(comptime v: u32) *const fn () void {
    return struct {
        fn f() void {
            if (kind != 0) return;
            armq = v;
            arm = true;
            armt = app.now_ms;
        }
    }.f;
}

/// node.group (Ctrl+G): tree.group / material.make_function with the selection.
fn opGroup() void {
    _ = rec() orelse return;
    if (kind >= 2) return;
    var m = selm;
    if (m == 0) return;
    var f = Fmt{};
    argStart(&f);
    while (m != 0) {
        const k: u32 = @ctz(m);
        m &= m - 1;
        argInt(&f, k);
    }
    runOp(if (kind == 0) "material.make_function" else "tree.group", argDone(&f));
    sel = 0;
    selm = 0;
}

fn opFit() void {
    frameView(0);
}
fn opFrameSel() void {
    frameView(1);
}

/// ne_frame(1: only the selected): zoom (25 .. 100 %) and pan so the nodes fill
/// the body, centred.
fn frameView(mode0: u32) void {
    if (bw < 120) {
        fitpend = mode0 + 1;
        app.dirty = true;
        return;
    }
    const r = rec() orelse return;
    layout(r);
    const mode = if (selm == 0) 0 else mode0;
    var xa: i32 = std.math.maxInt(i32);
    var ya: i32 = std.math.maxInt(i32);
    var xb: i32 = std.math.minInt(i32);
    var yb: i32 = std.math.minInt(i32);
    var k: u32 = if (kind == 0 and outputShown(r)) 0 else 1;
    while (k <= n) : (k += 1) {
        if (mode != 0 and !bit(selm, k)) continue;
        xa = @min(xa, gx[k]);
        xb = @max(xb, addgw(gx[k], k));
        ya = @min(ya, gy[k]);
        yb = @max(yb, gy[k] +% gh[k]);
    }
    if (xa > xb) return;
    var z = @divTrunc((bw - 60) * 100, xb -% xa +% 1);
    const z2 = @divTrunc((bh - 60) * 100, yb -% ya +% 1);
    if (z2 < z) z = z2;
    z = std.math.clamp(z, 25, 100);
    zoom = z;
    zoomApply();
    panx = (bw >> 1) - zs((xa +% xb) >> 1);
    pany = (bh >> 1) - zs((ya +% yb) >> 1);
    app.dirty = true;
}

/// The Material Output is shown (a material, not a function; the original counts
/// a function's hidden one at -30000 too when it frames all - not copied).
fn outputShown(r: *const Rec) bool {
    return kind == 0 and rd(r, MA_FUNC) != 1;
}

/// node.zoom <percent>: about the middle of the view.
fn opZoom() void {
    const v = nt.parseFloat(ops.arg, null) orelse return;
    const z = std.math.clamp(cvtt(v), 25, 200);
    zoomAt(z, (bw >> 1) + bx, (bh >> 1) + by);
}

/// node.preview 0|1 [sphere|cube|plane], node.thumbnails 0|1.
fn opPreview() void {
    var e: usize = 0;
    const v = nt.parseFloat(ops.arg, &e) orelse return;
    prev_on = if (cvtt(v) != 0) 1 else 0;
    var s = ops.arg[e..];
    while (s.len > 0 and s[0] == ' ') s = s[1..];
    if (s.len > 0) pshape = if (s[0] == 'c') 1 else if (s[0] == 'p') 2 else 0;
    app.dirty = true;
}
fn opThumbs() void {
    const v = nt.parseFloat(ops.arg, null) orelse return;
    thumbs_on = if (cvtt(v) != 0) 1 else 0;
    app.dirty = true;
}

/// node.toggle_tree (Tab): into a selected group / material function, else out
/// of one, else the material or the tree.
fn opTab() void {
    if (rec()) |r| {
        if (kind == 0) {
            if (sel != 0 and sel <= rd(r, GR_N) and typeOf(r, sel) == 42) {
                const f = cvtt(rdf(r, nodeOff(sel) + ND_P)) -% 1;
                if (f >= 0 and f < material.count and material.list[@intCast(f)].func == 1 and fpathn < 8) {
                    fpath[fpathn] = @intCast(f);
                    fpathn += 1;
                    return tabDone();
                }
            }
            if (fpathn != 0) {
                fpathn -= 1;
                return tabDone();
            }
            pref ^= 1;
            return tabDone();
        }
        if (kind == 1 and sel != 0 and sel <= rd(r, GR_N) and typeOf(r, sel) == 26) {
            const t = cvtt(rdf(r, nodeOff(sel) + ND_P));
            if (t -% 1 >= 0 and nt.get(@intCast(t - 1)) != null and pathn < 8) {
                path[pathn] = @intCast(t);
                pathn += 1;
                return tabDone();
            }
        }
    }
    if (pathn != 0) {
        pathn -= 1;
    } else pref ^= 1;
    tabDone();
}
fn tabDone() void {
    sel = 0;
    selm = 0;
    app.dirty = true;
}

pub const ctx_nodes = [_]cat.Item{
    .{ .op = "op_ne_add" },     .sep,                        .{ .op = "op_ne_dup" },  .{ .op = "op_ne_copy" }, .{ .op = "op_ne_paste" }, .{ .op = "op_ne_cut" }, .{ .op = "op_ne_del" }, .sep,
    .{ .op = "op_ne_coll" },    .{ .op = "op_ne_comment" },  .sep,                    .{ .op = "op_ne_alil" }, .{ .op = "op_ne_alit" },  .{ .op = "op_ne_disx" }, .{ .op = "op_ne_disy" }, .sep,
    .{ .op = "op_ne_fsel" },    .{ .op = "op_ne_fit" },
};

const Impl = ops.Impl;
pub const list = .{
    .{ "node.add_menu", Impl{ .run = opAddMenu, .ctx = .node } },
    .{ "node.delete", Impl{ .run = opDelete, .ctx = .node } },
    .{ "node.delete_key", Impl{ .run = opDelete, .ctx = .node } },
    .{ "node.toggle_tree", Impl{ .run = opTab, .ctx = .node } },
    .{ "node.group", Impl{ .run = opGroup, .ctx = .node } },
    .{ "node.view_fit", Impl{ .run = opFit, .ctx = .node } },
    .{ "node.copy", Impl{ .run = opCopy, .ctx = .node } },
    .{ "node.paste", Impl{ .run = opPaste, .ctx = .node } },
    .{ "node.duplicate", Impl{ .run = opDup, .ctx = .node } },
    .{ "node.duplicate_ctrl", Impl{ .run = opDup, .ctx = .node } },
    .{ "node.cut", Impl{ .run = opCut, .ctx = .node } },
    .{ "node.collapse", Impl{ .run = opCollapse, .ctx = .node } },
    .{ "node.comment", Impl{ .run = opComment, .ctx = .node } },
    .{ "node.frame_title", Impl{ .run = opFrameTitle, .ctx = .node } },
    .{ "node.align_left", Impl{ .run = opAlignL, .ctx = .node } },
    .{ "node.align_top", Impl{ .run = opAlignT, .ctx = .node } },
    .{ "node.distribute_x", Impl{ .run = opDistX, .ctx = .node } },
    .{ "node.distribute_y", Impl{ .run = opDistY, .ctx = .node } },
    .{ "node.quick_constant", Impl{ .run = armFn(16), .ctx = .node } },
    .{ "node.quick_color", Impl{ .run = armFn(17), .ctx = .node } },
    .{ "node.quick_texture", Impl{ .run = armFn(1), .ctx = .node } },
    .{ "node.quick_lerp", Impl{ .run = armFn(5639), .ctx = .node } },
    .{ "node.quick_multiply", Impl{ .run = armFn(775), .ctx = .node } },
    .{ "node.quick_add", Impl{ .run = armFn(263), .ctx = .node } },
    .{ "node.quick_divide", Impl{ .run = armFn(1031), .ctx = .node } },
    .{ "node.quick_power", Impl{ .run = armFn(1287), .ctx = .node } },
    .{ "node.quick_one_minus", Impl{ .run = armFn(4871), .ctx = .node } },
    .{ "node.quick_panner", Impl{ .run = armFn(23), .ctx = .node } },
    .{ "node.quick_normalize", Impl{ .run = armFn(3347), .ctx = .node } },
    .{ "node.quick_texcoord", Impl{ .run = armFn(10), .ctx = .node } },
    .{ "node.quick_bump", Impl{ .run = armFn(8), .ctx = .node } },
    .{ "node.zoom", Impl{ .run = opZoom, .ctx = .node } },
    .{ "node.preview", Impl{ .run = opPreview, .ctx = .node } },
    .{ "node.thumbnails", Impl{ .run = opThumbs, .ctx = .node } },
    .{ "node.view_selected", Impl{ .run = opFrameSel, .ctx = .node } },
};

// --- the header: which graph (the material, or a node tree the active object
//     runs), New Tree, Add, the palette, the preview pane, the thumbnails ----------------

fn treeLabel(k: usize) []const u8 {
    if (k == 0) return "Material";
    const r = nt.get(@intCast(k - 1)) orelse return "";
    return nt.name(r);
}
fn treeCount() usize {
    return @min(nt.count(), 79) + 1;
}
fn treeOn(k: usize) bool {
    return k == tsel;
}
var tsel: usize = 0;

/// ne_tree_cb: the material, or that tree on the active mesh.
fn treePick(k: usize) void {
    pathn = 0;
    if (k == 0) {
        pref = 1;
        app.dirty = true;
        return;
    }
    useTree(@intCast(k));
}

/// ne_use_tree(tree + 1): the active mesh runs it (its first Geometry Nodes or
/// Logic modifier, added when it has none).
fn useTree(t1: u32) void {
    pref = 0;
    const a = scene.active orelse return app.log("  modifiers need an active mesh object", .{});
    const o = &scene.objects[a];
    if (!o.kind.isMesh()) return app.log("  modifiers need an active mesh object", .{});
    undo.sync(); // (New Tree: the tree its own step, as the original's undo_push)
    undo.label("Node Tree");
    const ty_: u32 = if (logic.isLogic(t1 - 1)) mods.LOGIC else mods.GEONODES;
    var k: ?usize = null;
    for (o.mods.m[0..o.mods.n], 0..) |*d, i| {
        if (d.kind == ty_) {
            k = i;
            break;
        }
    }
    const ki = k orelse (mods.add(a, ty_) orelse return);
    mods.setF(&o.mods.m[ki], 0, @floatFromInt(t1));
    app.dirty = true;
}

/// ne_new_tree: tree.new, then the active mesh runs it.
fn newTree() void {
    runOp("tree.new", "");
    pathn = 0;
    useTree(nt.count());
}

/// ne_header_tools(r: right of the area's type button): a Zui part, its
/// pieces where the original's are.
pub fn header(i: i16, r: Rect) void {
    _ = rec();
    tsel = if (kind == 0) 0 else @as(usize, @intCast(mat + 1));
    // (right of the original's 130-wide type button, and short of its four
    // header buttons)
    const ar = app.N(i).rect;
    const x0_ = ar.x + 130 + 6;
    const y = r.y + 1;
    const lim = ar.right() - 4 * 22 - 10;
    if (x0_ + 150 > lim) return;
    const z = host.beginPart("nodes.head", @intCast(i), .{ .x = x0_, .y = y, .w = lim - x0_, .h = 22 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 6 });
    defer z.endHorizontal();
    const room = lim - x0_;
    // the graph: the material, or a node tree
    {
        const n_ = treeCount();
        const items = z.frameAllocator().alloc(zui.Choice, n_) catch return;
        for (items, 0..) |*c, k| c.* = .{ .label = treeLabel(k) };
        var gsel: usize = @min(tsel, n_ - 1);
        const d = z.dropdown("##graph", &gsel, items, .{ .width = .px(150) });
        z.tooltipRich(d, .{ .title = "Graph", .body = "Edit the material's nodes, or a node tree: picking one gives the active object a Geometry Nodes (or Logic) modifier running it" });
        ui.record("enum", treeLabel(gsel), host.rectOf(d.rect), true);
        if (d.changed) treePick(gsel);
    }
    if (156 + 80 > room) return;
    const nb = z.button("New Tree", .{ .width = .px(80), .height = .px(22) });
    z.tooltipRich(nb, .{ .title = "New Tree", .body = "A new geometry node tree, run by the active object" });
    if (nb.clicked) newTree();
    if (156 + 86 + 50 > room) return;
    const ab = z.button("Add", .{ .width = .px(50), .height = .px(22) });
    z.tooltipRich(ab, .{ .title = "Add", .shortcut = "Shift+A", .body = "Add a node (Shift+A in the editor, then type to search the list)" });
    const toggles = [_]struct { label: []const u8, w: f32, tip: []const u8 }{
        .{ .label = "Palette", .w = 90, .tip = "The palette: every node by category and a search field (click one to add it, or drag it onto the canvas)" },
        .{ .label = "Preview", .w = 90, .tip = "A material: shown on a sphere, cube or plane in the corner (drag it to turn it, click it for another shape)" },
        .{ .label = "Thumbnails", .w = 110, .tip = "A material's nodes: what each one gives, over a square, below it" },
    };
    var used: i32 = 156 + 86 + 56;
    for (toggles, 0..) |t, k| {
        used += @as(i32, @intFromFloat(t.w)) + 6;
        if (used > room) break;
        var on = switch (k) {
            0 => pal,
            1 => prev_on != 0,
            else => thumbs_on != 0,
        };
        const c = z.checkbox(t.label, &on, .{});
        z.tooltipRich(c, .{ .title = t.label, .body = t.tip });
        if (c.changed) {
            switch (k) {
                0 => pal = on,
                1 => prev_on = @intFromBool(on),
                else => thumbs_on = @intFromBool(on),
            }
            app.dirty = true;
        }
    }
    if (ab.clicked) {
        // the add menu, under the button (the pointer stays where it is)
        const kx = ui.mx;
        const ky = ui.my;
        ui.mx = @intFromFloat(ab.rect.x);
        ui.my = @intFromFloat(ab.rect.bottom() + 2);
        openMenu();
        ui.mx = kx;
        ui.my = ky;
    }
}

// --- the selected node in Properties > Material (matui.s node_details) ---------------

var nd_pick_slot: u32 = 0;
var nd_pick_kind: u8 = 0;
var nd_col: [3]u32 = @splat(0);
var nd_col_slot: u32 = 0;
var nd_name_buf: [24]u8 = undefined;

fn ndRec() ?*const Rec {
    if (kind != 0 or sel == 0 or mat < 0) return null;
    const r = matRec(@intCast(mat)) orelse return null;
    if (sel > rd(r, GR_N)) return null;
    return r;
}

fn ndMeta() ?MV {
    const r = ndRec() orelse return null;
    return metaOf(typeOf(r, sel));
}

fn ndListN() usize {
    const m = ndMeta() orelse return 1;
    return switch (nd_pick_kind) {
        2 => @min(images.count, 47) + 1,
        4 => material.count + 1,
        6 => m.ch2.len,
        else => if (m.ch.len == 0) 1 else m.ch.len,
    };
}
fn ndLabel(k: usize) []const u8 {
    const m = ndMeta() orelse return "None";
    return switch (nd_pick_kind) {
        2 => if (k == 0) "None" else images.nameOf(k - 1),
        4 => if (k == 0) "None" else material.list[k - 1].nameOf(),
        6 => if (k < m.ch2.len) m.ch2[k] else "",
        else => if (k < m.ch.len) m.ch[k] else "None",
    };
}
fn ndChecked(k: usize) bool {
    const r = ndRec() orelse return false;
    return cvt(rdf(r, nodeOff(sel) + ND_P + nd_pick_slot * 4)) == @as(i32, @intCast(k));
}
fn ndPick(k: usize) void {
    if (ndRec() == null) return;
    undo.label("Node Value");
    _ = gops.setSlot(@intCast(mat), sel, nd_pick_slot + 4, &.{@floatFromInt(k)});
    app.dirty = true;
}
fn ndColChanged() void {
    if (ndRec() == null) return;
    undo.label("Node Value");
    _ = gops.setSlot(@intCast(mat), sel, nd_col_slot + 1, &material.toLinear(nd_col[nd_col_slot]));
    app.dirty = true;
}

/// node_details: the node selected in the node editor (the material shown there):
/// its values and its inputs' constants as fields: numbers, choices, images,
/// functions, colours; a linked input says so. y: below them.
pub fn details(salt: usize, bd: Rect, ytop: i32, mi: usize) i32 {
    if (mat < 0 or mi != @as(usize, @intCast(mat))) return ytop;
    const r = ndRec() orelse return ytop;
    const o = nodeOff(sel);
    const t = rd(r, o);
    const m = metaOf(t) orelse return ytop;
    const bkit = @import("bkit.zig");
    var f = bkit.Flow.begin("props.node", salt, bd, ytop + 6);
    if (f.z) |z| ndDescribe(z, r, o, t, m, bkit);
    return f.end();
}

/// The node's rows (panel kit): its name (a parameter node), its values, its
/// inputs that are not linked.
fn ndDescribe(z: *zui.Ui, r: *const Rec, o: usize, t: u32, m: MV, bkit: type) void {
    var b: [64]u8 = undefined;
    const hd = std.fmt.bufPrint(&b, "Node: {s}", .{title(t)}) catch "Node";
    bkit.heading(z, hd);
    ui.record("heading", hd, host.rectOf(z.lastRect()), true);
    if (t >= 37 and t <= 39) {
        bkit.beginCaptioned(z, "Name", bkit.columnWidth(z) / 2);
        const nm = gops.paramName(@ptrCast(@alignCast(&r[o])), &nd_name_buf);
        if (bkit.textRow(z, "##node name", nm, "")) |s| {
            undo.label("Node Name");
            if (material.get(@intCast(mat))) |ma| {
                material.version +%= 1;
                gops.setParamName(&sg.nodesMut(ma)[sel - 1], s);
            }
            app.dirty = true;
        }
        bkit.endCaptioned(z);
    }
    // its values
    var p: u32 = 0;
    while (p < 4) : (p += 1) {
        const vn = m.val[p] orelse break;
        const v = rdf(r, o + ND_P + p * 4);
        z.pushIdInt(p);
        defer z.popId();
        switch (m.vk[p]) {
            1, 2, 4, 6 => {
                nd_pick_kind = m.vk[p];
                nd_pick_slot = p;
                const keep = nd_pick_kind;
                const cnt = ndListN();
                var c: i32 = cvt(v);
                if (c < 0) c = 0;
                if (keep == 1 or keep == 6) c = @min(c, @as(i32, @intCast(cnt)) - 1);
                var choice_k: usize = @intCast(c);
                bkit.beginCaptioned(z, vn, bkit.columnWidth(z) / 2);
                const tip: []const u8 = switch (keep) {
                    2 => "The image it samples",
                    4 => "The material function it runs (Tab in the node editor: edit it)",
                    else => "",
                };
                if (bkit.choice(z, "##pick", &choice_k, cnt, ndLabel, tip)) ndPick(choice_k);
                bkit.endCaptioned(z);
            },
            else => {
                var x = v;
                if (bkit.numberRow(z, vn, &x, .{ .step = 0.01, .min = -1000000, .max = 1000000, .decimals = 3, .tip = "The node's value (drag, or type a number or an expression)" }).changed) {
                    undo.label("Node Value");
                    _ = gops.setSlot(@intCast(mat), sel, p + 4, &.{x});
                    app.dirty = true;
                }
            },
        }
    }
    // its inputs
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const in_ = m.in[i] orelse break;
        z.pushIdInt(100 + i);
        defer z.popId();
        const io = o + ND_IN + i * 16;
        if (std.mem.readInt(u16, r[io..][0..2], .little) != 0) {
            bkit.infoPair(z, in_, "(linked)", bkit.columnWidth(z) / 2);
            continue;
        }
        const c3 = [3]f32{ rdf(r, io + 4), rdf(r, io + 8), rdf(r, io + 12) };
        if (m.ik[i] == 3) {
            const cp = @import("colorpick.zig");
            if (!cp.open or nd_col_slot != i) nd_col[i] = material.toSrgb(c3);
            const it = bkit.colourRow(z, in_, &nd_col[i], ndColChanged, "");
            if (it.hovered and !cp.open) nd_col_slot = i;
        } else {
            var x = c3[0];
            if (bkit.numberRow(z, in_, &x, .{ .step = 0.01, .min = -1000000, .max = 1000000, .decimals = 3, .tip = "The node's value (drag, or type a number or an expression)" }).changed) {
                undo.label("Node Value");
                _ = gops.setSlot(@intCast(mat), sel, i + 1, &.{ x, c3[1], c3[2] });
                app.dirty = true;
            }
        }
    }
}

// --- tests ---------------------------------------------------------------------------

const t_ = std.testing;

test "nodeed: zoom sizes and the original's rounding" {
    const keep = zoom;
    defer zoom = keep;
    zoom = 75;
    try t_.expectEqual(@as(i32, 128), zs(NW)); // (170 * 75 + 50) / 100
    try t_.expectEqual(@as(i32, 11), zs(UI_FONT_PX));
    try t_.expectEqual(@as(i32, -127), zs(-170)); // (truncated toward zero, + 50 first)
    try t_.expectEqual(@as(i32, 133), unzoom(100));
    try t_.expectEqual(@as(i32, 2), cvt(2.5));
    try t_.expectEqual(@as(i32, 4), cvt(3.5));
    try t_.expectEqual(@as(i32, -2), cvt(-2.5));
    try t_.expectEqual(std.math.minInt(i32), cvt(std.math.nan(f32)));
}

test "nodeed: numbers as the node editor writes them" {
    var f = Fmt{};
    f.num(0.3);
    try t_.expectEqualStrings("0.30", f.s());
    f = .{};
    f.num(-0.004);
    try t_.expectEqualStrings("0.00", f.s());
    f = .{};
    f.num(-1.25);
    try t_.expectEqualStrings("-1.25", f.s());
    f = .{};
    f.num(250.5);
    try t_.expectEqualStrings("250", f.s());
    f = .{};
    f.num4(-0.5);
    try t_.expectEqualStrings("-0.5000", f.s());
    f = .{};
    f.fix1(1.25);
    try t_.expectEqualStrings("1.2", f.s());
    f = .{};
    f.int(std.math.minInt(i32));
    try t_.expectEqualStrings("-2147483648", f.s());
}

test "nodeed: wires, the search, the knife" {
    const keep = grid;
    defer grid = keep;
    grid = 40;
    var p: [17][2]i32 = undefined;
    bez(0, 0, 200, 100, &p);
    try t_.expectEqual([2]i32{ 0, 0 }, p[0]);
    try t_.expectEqual([2]i32{ 200, 100 }, p[16]);
    try t_.expectEqual([2]i32{ 100, 50 }, p[8]);
    etit[0] = "Noise Texture";
    try t_.expect(visMatch(0, "tex"));
    try t_.expect(visMatch(0, "NOISE"));
    try t_.expect(!visMatch(0, "xt "));
    try t_.expect(!visMatch(0, "Textures"));
    try t_.expect(segNear(.{ 0, 0 }, .{ 100, 0 }, 50, 6));
    try t_.expect(!segNear(.{ 0, 0 }, .{ 100, 0 }, 50, 7));
    try t_.expectEqual(@as(i32, 1), orient(0, 0, 10, 0, 5, 5));
    try t_.expectEqual(@as(i32, 0), orient(0, 0, 10, 0, 20, 0));
}

test "nodeed: every type's meta reads (materials, trees, logic)" {
    const keep = kind;
    defer kind = keep;
    for ([_]u32{ 0, 1, 2 }) |k| {
        kind = k;
        var t: u32 = 1;
        while (t <= ntypes()) : (t += 1) {
            const m = metaOf(t).?;
            const c = counts(t);
            for (0..c[0]) |i| try t_.expect(m.in[i] != null);
            for (0..c[1]) |i| try t_.expect(m.val[i] != null);
            try t_.expect(title(t).len > 0);
        }
        try t_.expect(metaOf(0) == null);
        try t_.expect(metaOf(ntypes() + 1) == null);
    }
}
