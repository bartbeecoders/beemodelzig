// --dump-nodeval IN;OUT: what the tests read of shader graphs, as the original's
// nodeval(material, node, k, x, y, z, u, v) gives it (graph_probe: instances
// synced first). IN holds one query a line, "material node k x y z u v"; OUT
// gets each result's float bits in hex (or "none"), a line each.
const std = @import("std");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const gops = @import("graphops.zig");
const linux = std.os.linux;

fn zpath(b: *[512]u8, p: []const u8) ?[*:0]const u8 {
    if (p.len >= b.len) return null;
    @memcpy(b[0..p.len], p);
    b[p.len] = 0;
    return @ptrCast(b);
}

pub fn dumpNodeval(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ';');
    const in = it.next() orelse return;
    const out = it.next() orelse return;
    var pb: [512]u8 = undefined;
    const zi = zpath(&pb, in) orelse return;
    const ri = linux.open(zi, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(ri) != .SUCCESS) return;
    const fi: i32 = @intCast(ri);
    const a = std.heap.page_allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(fi, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        text.appendSlice(a, chunk[0..n]) catch break;
    }
    _ = linux.close(fi);
    var res: std.ArrayList(u8) = .empty;
    defer res.deinit(a);
    gops.syncCheck();
    sg.scene_time = gops.sceneTime();
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
    while (lines.next()) |l| {
        var w = std.mem.tokenizeScalar(u8, l, ' ');
        var v: ?f32 = null;
        blk: {
            const mi = material.find(w.next() orelse break :blk) orelse break :blk;
            const node = std.fmt.parseInt(u32, w.next() orelse break :blk, 10) catch break :blk;
            const k = std.fmt.parseInt(u32, w.next() orelse break :blk, 10) catch break :blk;
            var f: [5]f32 = @splat(0);
            for (&f) |*x| x.* = std.fmt.parseFloat(f32, w.next() orelse break) catch 0;
            v = sg.probe(&material.list[mi], material.list[0..material.count], node, k, f[0..3].*, f[3..5].*);
        }
        var b: [32]u8 = undefined;
        const s = if (v) |x| std.fmt.bufPrint(&b, "{x:0>8}\n", .{@as(u32, @bitCast(x))}) catch "none\n" else "none\n";
        res.appendSlice(a, s) catch break;
    }
    const zo = zpath(&pb, out) orelse return;
    const ro = linux.open(zo, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(ro) != .SUCCESS) return;
    const fo: i32 = @intCast(ro);
    defer _ = linux.close(fo);
    var o: usize = 0;
    while (o < res.items.len) {
        const n = linux.write(fo, res.items[o..].ptr, res.items.len - o);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        o += n;
    }
}
