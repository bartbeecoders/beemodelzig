// --dump-uv OUT[;OBJECT]: what the tests read of the UV work: the measures of an
// object's UVs (uv.zig), the mesh, the undo history, the UV editor's state.
const std = @import("std");
const scene = @import("scene.zig");
const uv = @import("uv.zig");
const undo = @import("undo.zig");
const uved = @import("uved.zig");
const linux = std.os.linux;

pub fn dump(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ';');
    const path = it.next() orelse return;
    var pb: [512]u8 = undefined;
    if (path.len >= pb.len) return;
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&pb);
    const r = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(r) != .SUCCESS) return;
    const fd: i32 = @intCast(r);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const oi = if (it.next()) |n| scene.find(n) else uv.target();
    if (oi) |i| {
        if (scene.meshOfObj(i)) |me| {
            for (std.enums.values(uv.Stat)) |k| w.print("{s} {d}\n", .{ @tagName(k), uv.stat(me, k) }) catch {};
            w.print("hasuv {d} hasseam {d} mesh {d}\n", .{ @intFromBool(me.uv.len > 0), @intFromBool(me.seam.len > 0), scene.objects[i].mesh.? }) catch {};
        }
    }
    w.print("steps {d} at {d}\n", .{ undo.count(), undo.current() }) catch {};
    for (0..undo.count()) |k| w.print("step {s}\n", .{undo.nameOf(k)}) catch {};
    uved.dump(&w);
    _ = linux.write(fd, buf[0..w.end].ptr, w.end);
}

/// --vselect "i j k": exactly these vertices of the edited mesh (or of the active
/// mesh, as vselect in the original's scripts).
pub fn vselect(spec: []const u8) void {
    const em = @import("editmesh.zig");
    const oi = uv.target() orelse return;
    const me = scene.meshOfObj(oi) orelse return;
    const a = std.heap.page_allocator;
    const s = a.alloc(bool, me.verts.len) catch return;
    defer a.free(s);
    @memset(s, false);
    var it = std.mem.tokenizeScalar(u8, spec, ' ');
    while (it.next()) |w| {
        const k = std.fmt.parseInt(usize, w, 10) catch continue;
        if (k < s.len) s[k] = true;
    }
    if (em.active) {
        @memcpy(em.sel, s);
        em.version +%= 1;
    } else scene.setMeshSel(scene.objects[oi].mesh.?, s);
}
