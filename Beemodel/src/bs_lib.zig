// BeeScript's content library builtins (script.s b_lib, b_libfind, b_libinfo;
// library.s lb_stat, lb_find_nth, lb_info): what the libraries hold, the
// search (it becomes the browser's), an asset's kind, id, blob, tags, what
// it uses and what uses it.
const std = @import("std");
const bs = @import("bscript.zig");
const lib = @import("library.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "lib", .f = libB },
    .{ .name = "libfind", .f = libfind },
    .{ .name = "libinfo", .f = libinfo },
};

/// lb_stat(k): 0 assets, 1 libraries, 2 thumbnails made, 3 still to make (or
/// being made: any other k counts these too), 4 matches for the search
pub fn stat(k: i32) f32 {
    lib.init();
    if (k == 1) return @floatFromInt(lib.nroot);
    if (k == 4) return @floatFromInt(lib.hits);
    var n: i32 = 0;
    for (lib.tab[0..lib.n]) |*r| {
        if (r.dead) continue;
        if (k == 0 or (if (k == 2) r.thumb == 2 else r.thumb < 2)) n += 1;
    }
    return @floatFromInt(n);
}

/// lib(k) -> the content library (lb_stat)
fn libB(a: []const V) Err!V {
    return bs.num(stat(bs.ci32(try bs.argNum(a[0]))));
}

/// lb_find_nth(words, i): the i-th match's name (null: none); the browser's
/// search becomes those words (120 bytes at most).
pub fn findNth(words: []const u8, first: i32) ?[]const u8 {
    lib.init();
    lib.setSearch(words);
    lib.match();
    app.dirty = true;
    var i = first;
    for (lib.tab[0..lib.n]) |*r| {
        if (r.hit != 1) continue;
        if (i == 0) return r.nameOf();
        i -%= 1;
    }
    return null;
}

/// libfind(words, i) -> the i-th asset (from 0) whose name, kind or tags hold
/// every word, or nil
fn libfind(a: []const V) Err!V {
    const i = bs.ci32(try bs.argNum(a[1]));
    const w = try bs.argStr(a[0]);
    const nm = findNth(w, i) orelse return bs.nil;
    return bs.text(nm);
}

var info_buf: [512]u8 = undefined;

/// lb_info(asset name or id, what) -> the text (null: no such asset). What is
/// told by its first letter ("kind", "id", "blob", "tags" / "thumb" by the
/// second); anything else is what it uses, or "users" (a fifth letter s).
pub fn info(asset: []const u8, what: []const u8) ?[]const u8 {
    lib.init();
    const i = lib.find(asset) orelse return null;
    const r = &lib.tab[i];
    const c0: u8 = if (what.len > 0) what[0] else 0;
    var hx: [16]u8 = undefined;
    switch (c0) {
        'k' => return lib.kinds[r.kind],
        'i' => return copy(lib.hex16(r.id, &hx)),
        'b' => return copy(lib.hex16(r.blob, &hx)),
        't' => {
            if (what.len > 1 and what[1] == 'h') return if (r.thumb == 2) "1" else "0";
            return r.tagsOf();
        },
        else => {
            // (the original reads the fifth byte whatever the length: past a
            // shorter word's end it finds its 0 or what follows; here: not 's')
            const users = what.len > 4 and what[4] == 's';
            return lib.depsLine(i, users, &info_buf);
        },
    }
}

fn copy(s: []const u8) []const u8 {
    @memcpy(info_buf[0..s.len], s);
    return info_buf[0..s.len];
}

/// libinfo(asset, what) -> "kind", "id", "blob", "tags", "uses", "users",
/// "thumb" (1 made) of an asset, or nil
fn libinfo(a: []const V) Err!V {
    const what = try bs.argStr(a[1]);
    const asset = try bs.argStr(a[0]);
    const s = info(asset, what) orelse return bs.nil;
    return bs.text(s);
}
