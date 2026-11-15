// The files that implement BeeScript's builtins, one per area of BeeModel.
// Each says `pub const builtins = [_]bscript.Builtin{ .{ .name = "pad", .f = pad }, ... };`
// with names from bs_table.zig (the original's table); bscript.zig checks at
// compile time that every name is one of the original's and given once.
// A new area adds its file here (one line) and touches nothing else.
pub const areas = .{
    @import("bs_lang.zig"),
    @import("bs_scene.zig"),
    @import("bs_cad.zig"),
    @import("bs_sketch.zig"),
    @import("bs_sdf.zig"),
    @import("bs_model.zig"),
    @import("bs_mat.zig"),
    @import("bs_nodes.zig"),
    @import("bs_paint.zig"),
    @import("bs_render.zig"),
    @import("bs_lib.zig"),
    @import("bs_proc.zig"),
    @import("bs_phys.zig"),
    @import("bs_land.zig"),
    @import("bs_anim.zig"),
    @import("bs_play.zig"),
    @import("bs_net.zig"),
};
