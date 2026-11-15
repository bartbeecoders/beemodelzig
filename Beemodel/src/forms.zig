// Operator forms (forms.s, dialog.s): an operator that takes values and is run
// from a menu, a button, a key or the palette without them gets a form. OK
// runs it with the values as its argument text, Cancel / Esc closes; the
// values stay for next time. Scripts and the console never see a form. The
// form is a Zui dialog (dialogs.client).
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");
const ui = @import("ui.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const dialogs = @import("dialogs.zig");
const menus = @import("menus.zig");

const W = 460;
const MAXF = 8;

/// form_ladd: landscape.add_<preset> [size m] [res n] [seed s] (each left out at its default)
const la_res = [_][]const u8{ "65", "129", "257", "513", "1025", "2049", "4097" };
const form_ladd: []const Field = &.{
        .{ .label = "Size (m)", .kind = .float, .lo = 10, .hi = 100000, .step = 1, .dec = 0, .def = 200, .prefix = "size" },
        .{ .label = "Samples a side", .kind = .options, .def = 3, .labels = &la_res, .words = &la_res, .prefix = "res" },
        .{ .label = "Seed (-1: the preset's)", .kind = .int, .lo = -1, .hi = 100000, .step = 0.1, .def = -1, .prefix = "seed" },
    };

const Kind = enum { int, float, options, toggle, text, active, colour, other };
const Field = struct {
    label: []const u8,
    kind: Kind,
    lo: f32 = -1e9,
    hi: f32 = 1e9,
    step: f32 = 1,
    dec: u8 = 0,
    def: f32 = 0,
    /// the words the operator expects: for options one each, a toggle's when on
    words: []const []const u8 = &.{},
    labels: []const []const u8 = &.{},
    /// a number with its keyword, left out at its default (FF_CHANGED)
    prefix: []const u8 = "",
    /// an empty text keeps its place in the argument as this
    empty: []const u8 = "",
    /// a text with spaces goes in quotes (dlg_form_arg: "10*wall + 2mm")
    quote: bool = false,
};
const Form = struct { op: []const u8, fields: []const Field };

const axes = [_][]const u8{ "X", "Y", "Z" };
const axes_kw = [_][]const u8{ "x", "y", "z" };
const bools = [_][]const u8{ "Union", "Difference", "Intersect" };
const bools_kw = [_][]const u8{ "union", "difference", "intersect" };

const ct_labels = [_][]const u8{ "Copy Location", "Copy Rotation", "Copy Scale", "Track To", "Limit Location", "Limit Rotation", "Limit Scale", "Child Of", "IK" };
const ct_words = [_][]const u8{ "copy_location", "copy_rotation", "copy_scale", "track_to", "limit_location", "limit_rotation", "limit_scale", "child_of", "ik" };

const forms = [_]Form{
    .{ .op = "render.settings", .fields = &.{
        .{ .label = "Width", .kind = .int, .lo = 16, .hi = 16384, .def = 1280 },
        .{ .label = "Height", .kind = .int, .lo = 16, .hi = 16384, .def = 720 },
        .{ .label = "Samples", .kind = .int, .lo = 1, .hi = 1000000, .def = 64 },
    } },
    .{ .op = "anim.range", .fields = &.{
        .{ .label = "Start frame", .kind = .int, .lo = -100000, .hi = 100000, .def = 1 },
        .{ .label = "End frame", .kind = .int, .lo = -100000, .hi = 100000, .def = 250 },
        .{ .label = "Frames per second", .kind = .int, .lo = 1, .hi = 1000, .def = 24 },
    } },
    .{ .op = "world.strength", .fields = &.{.{ .label = "Strength", .kind = .float, .lo = 0, .hi = 1000, .step = 0.01, .dec = 3, .def = 1 }} },
    .{ .op = "world.rotation", .fields = &.{.{ .label = "Rotation (degrees)", .kind = .float, .step = 0.5, .dec = 1 }} },
    .{ .op = "mesh.spin", .fields = &.{
        .{ .label = "Steps", .kind = .int, .lo = 1, .hi = 1024, .step = 0.2, .def = 12 },
        .{ .label = "Angle (degrees)", .kind = .float, .lo = -3600, .hi = 3600, .step = 0.5, .dec = 1, .def = 360 },
        .{ .label = "Axis", .kind = .options, .def = 1, .labels = &axes, .words = &axes_kw },
    } },
    .{ .op = "mesh.bisect", .fields = &.{
        .{ .label = "Point X", .kind = .float, .step = 0.01, .dec = 3 },
        .{ .label = "Point Y", .kind = .float, .step = 0.01, .dec = 3 },
        .{ .label = "Point Z", .kind = .float, .step = 0.01, .dec = 3 },
        .{ .label = "Normal X", .kind = .float, .lo = -1, .hi = 1, .step = 0.005, .dec = 3 },
        .{ .label = "Normal Y", .kind = .float, .lo = -1, .hi = 1, .step = 0.005, .dec = 3, .def = 1 },
        .{ .label = "Normal Z", .kind = .float, .lo = -1, .hi = 1, .step = 0.005, .dec = 3 },
    } },
    .{ .op = "object.boolean", .fields = &.{
        .{ .label = "Operation", .kind = .options, .def = 1, .labels = &bools, .words = &bools_kw },
        .{ .label = "Keep the cutters", .kind = .toggle, .words = &.{"keep"} },
    } },
    .{ .op = "object.move_to_folder", .fields = &.{.{ .label = "Folder (none: out of it)", .kind = .text, .words = &.{"none"} }} },
    // form_lkconn (link.zig): the address to mirror
    .{ .op = "link.connect", .fields = &.{.{ .label = "Address", .kind = .text }} },
    .{ .op = "shape.add", .fields = &.{.{ .label = "Name", .kind = .text, .words = &.{"Key"} }} },
    .{ .op = "anim.action", .fields = &.{.{ .label = "Name", .kind = .text, .words = &.{"Action"} }} },
    .{ .op = "anim.layer", .fields = &.{
        .{ .label = "Action", .kind = .text, .words = &.{"Action"} },
        .{ .label = "Object", .kind = .active, .empty = "-" },
        .{ .label = "Start frame", .kind = .float, .lo = -100000, .hi = 100000, .step = 0.2, .dec = 0, .def = 1 },
        .{ .label = "Influence", .kind = .float, .lo = 0, .hi = 1, .step = 0.005, .dec = 2, .def = 1 },
        .{ .label = "Mode", .kind = .options, .labels = &.{ "Replace", "Add" }, .words = &.{ "replace", "add" } },
    } },
    .{ .op = "constraint.add", .fields = &.{
        .{ .label = "Object", .kind = .active },
        .{ .label = "Type", .kind = .options, .labels = &ct_labels, .words = &ct_words },
        .{ .label = "Target", .kind = .text },
        .{ .label = "IK chain (bones, 0: to the root)", .kind = .int, .lo = 0, .hi = 64, .step = 0.05, .prefix = "chain" },
    } },
    .{ .op = "arm.parent", .fields = &.{
        .{ .label = "Mesh", .kind = .active },
        .{ .label = "Armature", .kind = .text },
        .{ .label = "Dual quaternion (keeps volume)", .kind = .toggle, .words = &.{"dual"} },
    } },
    .{ .op = "object.bake", .fields = &.{
        .{ .label = "Low mesh", .kind = .active },
        .{ .label = "High mesh", .kind = .text },
        .{ .label = "Map", .kind = .options, .labels = &.{ "Normal map", "Ambient occlusion", "Curvature" }, .words = &.{ "normal", "ao", "curvature" } },
        .{ .label = "Image", .kind = .text, .words = &.{"Bake"} },
        .{ .label = "Search distance (0: automatic)", .kind = .float, .lo = 0, .hi = 1000, .step = 0.005, .dec = 3 },
    } },
    .{ .op = "paint.color", .fields = &.{.{ .label = "Colour", .kind = .colour, .def = 15088680 }} },
    // form_lbsave, form_lbtag (the content library: library.zig, libui.zig)
    .{ .op = "lib.save", .fields = &.{
        .{ .label = "Save", .kind = .options, .labels = &.{ "The active object", "Its rig", "The whole scene", "Its material" }, .words = &.{ "object", "rig", "scene", "material" } },
        .{ .label = "Name", .kind = .active },
        .{ .label = "Tags", .kind = .text },
    } },
    .{ .op = "lib.tag_selected", .fields = &.{.{ .label = "Tags", .kind = .text }} },
    .{ .op = "vc.branch", .fields = &.{.{ .label = "Name", .kind = .text, .words = &.{"feature"} }} },
    .{ .op = "vc.merge", .fields = &.{.{ .label = "Branch", .kind = .text }} },
    .{ .op = "param.set", .fields = &.{
        .{ .label = "Name", .kind = .text, .words = &.{"width"} },
        .{ .label = "Value", .kind = .text, .words = &.{"10mm"}, .quote = true },
    } },
    .{ .op = "landscape.tiles", .fields = &.{.{ .label = "Tiles a side", .kind = .int, .lo = 2, .hi = 16, .def = 2 }} },
    .{ .op = "landscape.add_flat", .fields = form_ladd },
    .{ .op = "landscape.add_hills", .fields = form_ladd },
    .{ .op = "landscape.add_mountains", .fields = form_ladd },
    .{ .op = "landscape.add_canyon", .fields = form_ladd },
    .{ .op = "landscape.add_dunes", .fields = form_ladd },
    .{ .op = "landscape.add_island", .fields = form_ladd },
    .{ .op = "scene.units", .fields = &.{.{ .label = "One scene unit is", .kind = .options, .def = 2, .labels = &.{ "Millimetres", "Centimetres", "Metres", "Inches" }, .words = &.{ "mm", "cm", "m", "in" } }} },
    .{ .op = "mesh.print_check", .fields = &.{.{ .label = "Thinnest wall allowed (mm)", .kind = .float, .lo = 0.05, .hi = 100, .step = 0.01, .dec = 2, .def = 1 }} },
    .{ .op = "cad.sketch", .fields = &.{
        .{ .label = "Name", .kind = .text, .words = &.{"Sketch"} },
        .{ .label = "Plane", .kind = .options, .def = 1, .labels = &.{ "XY (front)", "XZ (ground)", "YZ (side)" }, .words = &.{ "XY", "XZ", "YZ" } },
        .{ .label = "Offset", .kind = .float, .step = 0.01, .dec = 3 },
    } },
    // rigid.add [active|passive] [shape] [mass m] [friction f] [bounce b] [damping d]
    // (forms.s form_rigid: the numbers left out at their defaults)
    .{ .op = "object.shatter", .fields = &.{
        .{ .label = "Pattern", .kind = .options, .labels = &.{ "Shards", "Bricks", "Balls" }, .words = &.{ "shards", "bricks", "balls" } },
        .{ .label = "Preset", .kind = .options, .labels = &.{ "None", "Brick wall", "Glass", "Stone", "Gravel balls" }, .words = &.{ "none", "brickwall", "glass", "stone", "gravel" }, .prefix = "preset" },
        .{ .label = "Count", .kind = .float, .lo = 1, .hi = 4096, .step = 1, .dec = 0, .def = 50, .prefix = "count" },
        .{ .label = "Seed", .kind = .float, .lo = 0, .hi = 100000, .step = 1, .dec = 0, .def = 1, .prefix = "seed" },
        .{ .label = "Glue (N/m2)", .kind = .float, .lo = 0, .hi = 10000000, .step = 500, .dec = 0, .def = 0, .prefix = "glue" },
        .{ .label = "Breaks at (N s, 0 = now)", .kind = .float, .lo = 0, .hi = 100000, .step = 0.5, .dec = 1, .def = 0, .prefix = "impact" },
        .{ .label = "Gap (m)", .kind = .float, .lo = 0, .hi = 1, .step = 0.001, .dec = 3, .def = 0, .prefix = "gap" },
    } },
    .{ .op = "rigid.add", .fields = &.{
        .{ .label = "Type", .kind = .options, .labels = &.{ "Active", "Passive" }, .words = &.{ "active", "passive" } },
        .{ .label = "Shape", .kind = .options, .labels = &.{ "Box", "Sphere", "Capsule", "Convex hull", "Compound" }, .words = &.{ "box", "sphere", "capsule", "hull", "compound" } },
        .{ .label = "Mass (kg)", .kind = .float, .lo = 0.001, .hi = 1000000, .step = 0.02, .dec = 3, .def = 1, .prefix = "mass" },
        .{ .label = "Friction", .kind = .float, .lo = 0, .hi = 2, .step = 0.005, .dec = 3, .def = 0.5, .prefix = "friction" },
        .{ .label = "Bounce", .kind = .float, .lo = 0, .hi = 1, .step = 0.005, .dec = 3, .def = 0, .prefix = "bounce" },
        .{ .label = "Damping", .kind = .float, .lo = 0, .hi = 10, .step = 0.005, .dec = 3, .def = 0.05, .prefix = "damping" },
    } },
    // cloth.add [cloth|soft|collider] [mass m] [damping d] [thickness t] [friction f] [self]
    // (forms.s form_cloth: the numbers left out at their defaults)
    .{ .op = "cloth.add", .fields = &.{
        .{ .label = "Kind", .kind = .options, .labels = &.{ "Cloth", "Soft body", "Collider" }, .words = &.{ "cloth", "soft", "collider" } },
        .{ .label = "Mass (kg)", .kind = .float, .lo = 0.001, .hi = 100000, .step = 0.01, .dec = 3, .def = 1, .prefix = "mass" },
        .{ .label = "Damping", .kind = .float, .lo = 0, .hi = 10, .step = 0.005, .dec = 3, .def = 0, .prefix = "damping" },
        .{ .label = "Thickness", .kind = .float, .lo = 0, .hi = 10, .step = 0.001, .dec = 3, .def = 0, .prefix = "thickness" },
        .{ .label = "Friction", .kind = .float, .lo = 0, .hi = 2, .step = 0.005, .dec = 3, .def = 0, .prefix = "friction" },
        .{ .label = "Self collision", .kind = .toggle, .words = &.{"self"} },
    } },
    // rigid.joint <fixed|hinge|point|slider> <object> <object|world> [axis x y z] (form_rjoint)
    .{ .op = "rigid.joint", .fields = &.{
        .{ .label = "Type", .kind = .options, .def = 1, .labels = &.{ "Fixed (welded)", "Hinge (turns about an axis)", "Point (a ball joint)", "Slider (along an axis)" }, .words = &.{ "fixed", "hinge", "point", "slider" } },
        .{ .label = "Object", .kind = .active, .quote = true, .empty = "\"\"" },
        .{ .label = "Tied to", .kind = .other, .quote = true, .empty = "\"\"" },
        .{ .label = "Axis", .kind = .options, .def = 1, .labels = &axes, .words = &.{ "axis 1 0 0", "axis 0 1 0", "axis 0 0 1" } },
    } },
    // mech.joint <type> <part> <parent> axis x y z value <e> (forms.s form_joint)
    .{ .op = "mech.joint", .fields = &.{
        .{ .label = "Type", .kind = .options, .labels = &.{ "Revolute (turns)", "Slider (slides)" }, .words = &.{ "revolute", "slider" } },
        .{ .label = "Part", .kind = .active, .quote = true, .empty = "\"\"" },
        .{ .label = "Joined to", .kind = .text, .words = &.{"world"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Axis", .kind = .options, .def = 1, .labels = &axes, .words = &.{ "axis 1 0 0", "axis 0 1 0", "axis 0 0 1" } },
        .{ .label = "Value", .kind = .text, .words = &.{"0"}, .quote = true, .empty = "\"\"", .prefix = "value" },
    } },
    // the features (forms.s form_pad .. form_infill): texts are values or
    // expressions, quoted with spaces, "" when empty
    .{ .op = "cad.pad", .fields = &.{
        .{ .label = "Part", .kind = .text, .words = &.{"Body"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Distance", .kind = .text, .words = &.{"10"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Direction", .kind = .options, .labels = &.{ "Along the normal", "Symmetric", "Reversed" }, .words = &.{ "normal", "symmetric", "reverse" } },
    } },
    .{ .op = "cad.pocket", .fields = &.{
        .{ .label = "Part", .kind = .text, .words = &.{"Body"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Depth", .kind = .text, .words = &.{"5"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Extent", .kind = .options, .labels = &.{ "Along the normal", "Through all", "Symmetric", "Reversed" }, .words = &.{ "normal", "through", "symmetric", "reverse" } },
    } },
    .{ .op = "cad.revolve", .fields = &.{
        .{ .label = "Part", .kind = .text, .words = &.{"Body"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Angle", .kind = .text, .words = &.{"360deg"}, .quote = true, .empty = "\"\"" },
        .{ .label = "About the axis", .kind = .options, .labels = &.{ "U (the sketch's horizontal)", "V (the sketch's vertical)" }, .words = &.{ "u", "v" } },
    } },
    .{ .op = "cad.hole", .fields = &.{
        .{ .label = "Part", .kind = .text, .words = &.{"Body"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Diameter", .kind = .text, .words = &.{"5"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Depth", .kind = .text, .words = &.{"0"}, .quote = true, .empty = "\"\"" },
    } },
    .{ .op = "cad.shell", .fields = &.{
        .{ .label = "Pad feature (number in the CAD tab, from 0)", .kind = .int, .lo = 0, .hi = 63, .step = 0.05 },
        .{ .label = "Wall", .kind = .text, .words = &.{"2"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Opening", .kind = .options, .labels = &.{ "Open at the top", "Open at the bottom" }, .words = &.{ "normal", "bottom" } },
    } },
    .{ .op = "cad.fillet", .fields = &.{
        .{ .label = "Radius", .kind = .text, .words = &.{"1"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Edges", .kind = .options, .labels = &edge_labels, .words = &edge_words },
    } },
    .{ .op = "cad.chamfer", .fields = &.{
        .{ .label = "Size", .kind = .text, .words = &.{"1"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Edges", .kind = .options, .labels = &edge_labels, .words = &edge_words },
    } },
    .{ .op = "cad.pattern", .fields = &.{
        .{ .label = "Feature to repeat (from 0)", .kind = .int, .lo = 0, .hi = 63, .step = 0.05 },
        .{ .label = "Count", .kind = .int, .lo = 2, .hi = 1000, .step = 0.1, .def = 3 },
        .{ .label = "Spacing", .kind = .text, .words = &.{"10"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Axis", .kind = .options, .labels = &axes, .words = &axes_kw },
        .{ .label = "Arrangement", .kind = .options, .labels = &.{ "In a row", "Around the axis" }, .words = &.{ "linear", "circular" } },
    } },
    .{ .op = "cad.infill", .fields = &.{
        .{ .label = "Shell feature (from 0)", .kind = .int, .lo = 0, .hi = 63, .step = 0.05, .def = 1 },
        .{ .label = "Lattice", .kind = .options, .labels = &.{ "Gyroid", "Grid" }, .words = &.{ "gyroid", "grid" } },
        .{ .label = "Cell size", .kind = .text, .words = &.{"5"}, .quote = true, .empty = "\"\"" },
        .{ .label = "Wall", .kind = .text, .words = &.{"0.8"}, .quote = true, .empty = "\"\"" },
    } },
};

const edge_labels = [_][]const u8{ "All sharp edges", "Vertical edges", "Horizontal edges", "Top edges", "Bottom edges" };
const edge_words = [_][]const u8{ "all", "vertical", "horizontal", "top", "bottom" };

/// The text of each text field: the operator's default the first time, then
/// what was typed; `active` fields the active object's name each time.
var texts: [forms.len][MAXF][64]u8 = undefined;
var text_len: [forms.len][MAXF]usize = @splat(@splat(0));
var text_seen: [forms.len]bool = @splat(false);

var vals: [forms.len][MAXF]f32 = blk: {
    var v: [forms.len][MAXF]f32 = undefined;
    for (forms, 0..) |f, i| {
        v[i] = @splat(0);
        for (f.fields, 0..) |fd, k| v[i][k] = fd.def;
    }
    break :blk v;
};

var cur: usize = 0;
var op_i: usize = 0;
var arg_buf: [256]u8 = undefined;

/// The active object, what a field of it starts with (none: empty).
fn activeName() []const u8 {
    const scene = @import("scene.zig");
    return if (scene.active) |a| scene.objects[a].name() else "";
}

/// FK_OTHER (dialog.s other_selected): another selected object's name, or world.
fn otherName() []const u8 {
    const scene = @import("scene.zig");
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (scene.active != null and scene.active.? == k) continue;
        if (o.selected) return o.name();
    }
    return "world";
}

/// The argument text of a form's values (dlg_form_arg); `text`: a field's text.
pub fn argText(buf: []u8, f: *const Form, v: []const f32, text: []const []const u8) []const u8 {
    var w: usize = 0;
    for (f.fields, 0..) |fd, k| {
        var one: [48]u8 = undefined;
        const s: []const u8 = switch (fd.kind) {
            .int => if (fd.prefix.len > 0 and v[k] == fd.def) "" else if (fd.prefix.len > 0) (std.fmt.bufPrint(&one, "{s} {d}", .{ fd.prefix, @as(i64, @intFromFloat(@round(v[k]))) }) catch "") else (std.fmt.bufPrint(&one, "{d}", .{@as(i64, @intFromFloat(@round(v[k])))}) catch ""),
            // (a keyword, left out at its default: FF_CHANGED - "mass 2")
            .float => if (fd.prefix.len > 0 and v[k] == fd.def) "" else if (fd.prefix.len > 0) (std.fmt.bufPrint(&one, "{s} {d}", .{ fd.prefix, v[k] }) catch "") else (std.fmt.bufPrint(&one, "{d}", .{v[k]}) catch ""),
            .options => fd.words[@min(fd.words.len - 1, @as(usize, @intFromFloat(v[k])))],
            .toggle => if (v[k] != 0) fd.words[0] else "",
            .text, .active, .other => if (text[k].len > 0) text[k] else fd.empty,
            .colour => blk: { // "r g b", 0..255 as shown
                const c: u32 = @intFromFloat(v[k]);
                break :blk std.fmt.bufPrint(&one, "{d} {d} {d}", .{ c >> 16 & 255, c >> 8 & 255, c & 255 }) catch "";
            },
        };
        if (s.len == 0) continue;
        const q = fd.quote and std.mem.indexOfScalar(u8, s, ' ') != null;
        // a text's keyword before it ("value 30deg": form_joint's p_value)
        const pre: []const u8 = if (fd.prefix.len > 0 and (fd.kind == .text or fd.kind == .active or fd.kind == .options)) fd.prefix else "";
        const piece = std.fmt.bufPrint(buf[w..], "{s}{s}{s}{s}{s}{s}", .{ if (w > 0) " " else "", pre, if (pre.len > 0) " " else "", if (q) "\"" else "", s, if (q) "\"" else "" }) catch break;
        w += piece.len;
    }
    return buf[0..w];
}

/// Run from the UI with no values: its form instead. True when it opened.
pub fn offer(i: usize) bool {
    const id = cat.entries[i].id;
    for (forms, 0..) |f, k| {
        if (!std.mem.eql(u8, f.op, id)) continue;
        cur = k;
        op_i = i;
        for (f.fields, 0..) |fd, q| {
            if (fd.kind == .active) {
                keepText(q, activeName());
            } else if (fd.kind == .other) {
                keepText(q, otherName());
            } else if (fd.kind == .text and !text_seen[k]) {
                keepText(q, if (fd.words.len > 0) fd.words[0] else "");
            }
        }
        text_seen[k] = true;
        menus.close();
        dialogs.open(.form);
        return true;
    }
    return false;
}

fn keepText(k: usize, s: []const u8) void {
    const n = @min(s.len, texts[cur][k].len);
    @memcpy(texts[cur][k][0..n], s[0..n]);
    text_len[cur][k] = n;
}

fn ok() void {
    var tx: [MAXF][]const u8 = undefined;
    for (&tx, 0..) |*t, k| t.* = texts[cur][k][0..text_len[cur][k]];
    const a = argText(&arg_buf, &forms[cur], &vals[cur], &tx);
    dialogs.close();
    const old = ops.arg;
    defer ops.arg = old;
    ops.arg = a;
    ops.scripted = true;
    defer ops.scripted = false;
    ops.run(op_i);
}

/// doc_plain: the doc up to its syntax ("Hollow a part: cad.shell <pad> ..."
/// -> "Hollow a part"); all syntax: as it is.
fn docPlain(doc: []const u8, id: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, doc, id) orelse return doc;
    var n = @min(at, 158);
    while (n > 0 and (doc[n - 1] == ' ' or doc[n - 1] == ':')) n -= 1;
    return if (n == 0) doc else doc[0..n];
}

/// The caption column of a field with its caption outside (texts, options,
/// colours), as dialog.s lays them out.
const CAPTION_W = 126;

/// The form, a Zui dialog: the operator's name, its doc, the fields, Cancel
/// and OK (Enter runs it, Esc closes).
pub fn describe(z: *zui.Ui) void {
    const f = &forms[cur];
    const e = &cat.entries[op_i];
    if (!dialogs.beginDialog(z, e.label, W - 40, false)) return;
    defer dialogs.endDialog(z);
    z.wrappedText(docPlain(e.doc, e.id), .{ .color = host.col(ui.th.text_dim), .width = W - 40 });
    z.spacer(.{ .fixed = 4 });
    var names: [MAXF][72]u8 = undefined;
    for (f.fields, 0..) |fd, k| {
        z.pushIdInt(cur * 16 + k);
        defer z.popId();
        const hidden = std.fmt.bufPrint(&names[k], "##{s}", .{fd.label}) catch fd.label;
        switch (fd.kind) {
            .int, .float => {
                var v: f64 = vals[cur][k];
                const r = z.numberField(fd.label, &v, .{
                    .width = .fill,
                    .min = fd.lo,
                    .max = fd.hi,
                    .step = if (fd.kind == .float) fd.step else null,
                    // BeeModel's fields: a pixel of drag is a step
                    .drag_step = fd.step,
                    .decimals = if (fd.kind == .int) 0 else fd.dec,
                    .label = .inside,
                    .evaluator = &bkit.evaluator,
                });
                if (r.changed) vals[cur][k] = @floatCast(if (fd.kind == .int) @round(v) else v);
            },
            .text, .active, .other => {
                bkit.beginCaptioned(z, fd.label, CAPTION_W);
                _ = z.textInput(hidden, &texts[cur][k], &text_len[cur][k], .{ .width = .fill, .select_on_click = true });
                bkit.endCaptioned(z);
            },
            .colour => {
                bkit.beginCaptioned(z, fd.label, CAPTION_W);
                const rgb: u32 = @intFromFloat(vals[cur][k]);
                var c = host.col(rgb);
                if (z.colorEdit(hidden, &c, .{ .alpha = false, .compact = true }).changed) {
                    vals[cur][k] = @floatFromInt(@as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b);
                }
                bkit.endCaptioned(z);
            },
            .toggle => {
                var on = vals[cur][k] != 0;
                if (bkit.checkRow(z, fd.label, &on, "").changed) vals[cur][k] = if (on) 1 else 0;
            },
            .options => {
                bkit.beginCaptioned(z, fd.label, CAPTION_W);
                var choices: [16]zui.Choice = undefined;
                const n = @min(fd.labels.len, choices.len);
                for (fd.labels[0..n], 0..) |l, q| choices[q] = .{ .label = l };
                var sel: usize = @min(@as(usize, @intFromFloat(vals[cur][k])), n - 1);
                if (z.dropdown(hidden, &sel, choices[0..n], .{ .width = .fill }).changed) vals[cur][k] = @floatFromInt(sel);
                bkit.endCaptioned(z);
            },
        }
    }
    if (z.dialogButtons(&.{ "Cancel", "OK" }, .{ .default = 1, .cancel = 0 })) |b| {
        if (b == 0) dialogs.close() else ok();
    }
}

/// (tests: a form by its operator, so new forms anywhere in the table don't shift them)
fn formOf(comptime op: []const u8) *const Form {
    for (&forms) |*f| if (std.mem.eql(u8, f.op, op)) return f;
    @panic("no form for " ++ op);
}

test "argument text" {
    var b: [64]u8 = undefined;
    const t = std.testing;
    const spin = formOf("mesh.spin");
    const none: [MAXF][]const u8 = @splat("");
    try t.expectEqualStrings("12 360 y", argText(&b, spin, &.{ 12, 360, 1 }, &none));
    const bo = formOf("object.boolean");
    try t.expectEqualStrings("difference", argText(&b, bo, &.{ 1, 0 }, &none));
    try t.expectEqualStrings("union keep", argText(&b, bo, &.{ 0, 1 }, &none));
    try t.expectEqualStrings("Props", argText(&b, formOf("object.move_to_folder"), &.{0}, &.{"Props"}));
    try t.expectEqualStrings("Smile", argText(&b, formOf("shape.add"), &.{0}, &.{"Smile"}));
    const lay = formOf("anim.layer");
    try t.expectEqualStrings("Walk - 1 1 replace", argText(&b, lay, &.{ 0, 0, 1, 1, 0 }, &.{ "Walk", "", "", "", "" }));
    try t.expectEqualStrings("Walk Cube 1 1 add", argText(&b, lay, &.{ 0, 0, 1, 1, 1 }, &.{ "Walk", "Cube", "", "", "" }));
    const con = formOf("constraint.add");
    try t.expectEqualStrings("Rig:Hand ik Goal chain 2", argText(&b, con, &.{ 0, 8, 0, 2 }, &.{ "Rig:Hand", "", "Goal", "" }));
    try t.expectEqualStrings("Cube limit_location", argText(&b, con, &.{ 0, 4, 0, 0 }, &.{ "Cube", "", "", "" }));
    // form_joint: a text's keyword, quotes round spaces, "" for nothing
    const jt = for (&forms) |*f| {
        if (std.mem.eql(u8, f.op, "mech.joint")) break f;
    } else unreachable;
    try t.expectEqualStrings("revolute Wheel world axis 0 1 0 value 0", argText(&b, jt, &.{ 0, 0, 0, 1, 0 }, &.{ "", "Wheel", "world", "", "0" }));
    try t.expectEqualStrings("slider \"\" Pin axis 0 0 1 value \"a * 2\"", argText(&b, jt, &.{ 1, 0, 0, 2, 0 }, &.{ "", "", "Pin", "", "a * 2" }));
    // form_rigid: the numbers left out at their defaults (FF_CHANGED), with their keywords
    const rf = for (&forms) |*f| {
        if (std.mem.eql(u8, f.op, "rigid.add")) break f;
    } else unreachable;
    try t.expectEqualStrings("active box", argText(&b, rf, &.{ 0, 0, 1, 0.5, 0, 0.05 }, &none));
    try t.expectEqualStrings("passive compound mass 2 bounce 0.5", argText(&b, rf, &.{ 1, 4, 2, 0.5, 0.5, 0.05 }, &none));
    // form_rjoint: the active object, another selected one or world
    const rj = for (&forms) |*f| {
        if (std.mem.eql(u8, f.op, "rigid.joint")) break f;
    } else unreachable;
    try t.expectEqualStrings("hinge Box world axis 0 1 0", argText(&b, rj, &.{ 1, 0, 0, 1 }, &.{ "", "Box", "world", "" }));
    try t.expectEqualStrings("fixed \"Big Box\" Floor axis 0 0 1", argText(&b, rj, &.{ 0, 0, 0, 2 }, &.{ "", "Big Box", "Floor", "" }));
}
