// BeeScript's live link, version control and co-editing builtins (script.s
// b_livelink, b_vcinfo, b_vctext, b_costat, b_cohash). vcinfo / vctext ask
// vc.zig; the others answer as the original does when its subsystem has
// nothing (no live link serving, no co-editing session) until theirs come.
const std = @import("std");
const bs = @import("bscript.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "livelink", .f = livelink },
    .{ .name = "vcinfo", .f = vcinfo },
    .{ .name = "vctext", .f = vctext },
    .{ .name = "costat", .f = costat },
    .{ .name = "cohash", .f = cohash },
};

/// livelink(k) (link_stat, link.zig): 0 serving, 1 peers synced, 2 bytes
/// sent, 3 messages sent, 4 mirroring, 5 messages received, 6 transforms held
/// back, 7 snapshots sent (a single float, as the original's).
fn livelink(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    return bs.num(@floatCast(@import("link.zig").stat(k)));
}

/// vcinfo(k) (vc_stat): 0 has a history, 1 commits on the branch, 2
/// branches, 3 diff rows, 4 added, 5 removed, 6 changed, 7 conflicts, 8 open,
/// 9 merging (vc.zig); 0 without a file.
fn vcinfo(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    return bs.num(@floatCast(@import("vc.zig").stat(k)));
}

/// vctext(what [, row]) (vc_text): 0 the branch, 1 a diff row, 2 a merge
/// conflict, 3 the last commit's message; nil when none (or no file). (The
/// original makes "<file>.vc" whenever it looks: the port does too.)
fn vctext(a: []const V) Err!V {
    const what = bs.ci32(try bs.argNum(a[0]));
    var row: i32 = 0;
    if (a.len >= 2) row = bs.ci32(try bs.argNum(a[1]));
    const t = @import("vc.zig").text(what, row) orelse return bs.nil;
    return bs.text(t);
}

/// costat(k) (co_stat): 0 in a session, 1 connections, 2 objects in the
/// document, 3 peers seen, 4 operations made, 5 applied, 6 our peer id, 7
/// following, 8 / 9 the agent's / the user's undo log's bytes (a float, as the
/// original's).
fn costat(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    return bs.num(@floatCast(@import("cosync.zig").stat(k)));
}

/// cohash() (co_hash_doc): the co-editing document's hash, 16 hex digits:
/// every peer's is the same once they converged (no session: FNV-1a's offset
/// basis).
fn cohash(_: []const V) Err!V {
    var b: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&b, "{x:0>16}", .{@import("cosync.zig").hashDoc()}) catch unreachable;
    return bs.text(&b);
}

test "cohash's 16 digits are the FNV-1a offset basis, lower case" {
    var b: [16]u8 = undefined;
    _ = try std.fmt.bufPrint(&b, "{x:0>16}", .{@as(u64, 0xcbf29ce484222325)});
    try std.testing.expectEqualStrings("cbf29ce484222325", &b);
}
