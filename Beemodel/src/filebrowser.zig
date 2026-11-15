// The file browser (Open, Save As, imports and exports, a folder): Zui's
// zui_files in a dialog. Folders first, then the files of the kinds asked
// for, in columns (name, size, date; a click on a column sorts); a click
// picks, a double-click (or Enter) opens or takes. Back, forward and up,
// the folder's parts as crumbs, Ctrl+L to type a path (Tab completes); a
// filter, Hidden files (Ctrl+H), All files. Places on the left: home,
// ~/BeeModel, the whole computer, and the last folders used. Saving over a
// file asks first; an export's options (Selected objects only, the up axis,
// the scale) are a panel beside the list. A modal host client.
const std = @import("std");
const linux = std.os.linux;
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const zui = @import("zui");
const files = @import("zui_files");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;

/// folder: a folder is what is wanted (or a file in it).
pub const Mode = enum { open, save, folder };

pub var open_: bool = false;
var mode: Mode = .open;
var title: []const u8 = "";
var ext: []const u8 = ".bee";
var on_done: *const fn ([]const u8) void = undefined;

var dir_buf: [512]u8 = undefined;
var dir_len: usize = 0;
var home_buf: [256]u8 = undefined;
var home_len: usize = 0;

// recent folders (this session)
var recent: [6][512]u8 = undefined;
var recent_len: [6]usize = @splat(0);

pub fn setHome(h: ?[]const u8) void {
    const s = h orelse "/";
    home_len = @min(s.len, home_buf.len);
    @memcpy(home_buf[0..home_len], s[0..home_len]);
}

pub fn homeDir() []const u8 {
    return home();
}

fn home() []const u8 {
    return if (home_len > 0) home_buf[0..home_len] else "/";
}

fn dir() []const u8 {
    return dir_buf[0..dir_len];
}

/// Start in this folder next time (Save As starts where the file is).
pub fn goTo(d: []const u8) void {
    if (isDir(d)) {
        const n = @min(d.len, dir_buf.len);
        @memcpy(dir_buf[0..n], d[0..n]);
        dir_len = n;
    }
}

/// This one is an export: selected only, up axis, scale beside the list.
pub var export_options = false;
/// The export's up axis and scale can be chosen (WGF_EXPAXIS; 3MF: always mm, Z up).
pub var export_axis = true;
var opt_sel = false;
var opt_zup = false;
var opt_scale: f32 = 1;

var browser: ?files.Browser = null;
var src: Disk = .{};
var opening = false;
var suggested_buf: [256]u8 = undefined;
var suggested_len: usize = 0;

/// Open the browser: `done` gets the chosen path.
pub fn show(m: Mode, t: []const u8, extension: []const u8, suggested: []const u8, done: *const fn ([]const u8) void) void {
    export_options = false;
    export_axis = true;
    mode = m;
    title = t;
    ext = extension;
    on_done = done;
    open_ = true;
    opening = true;
    if (dir_len == 0) {
        // ~/BeeModel when it is there, else home
        var b: [512]u8 = undefined;
        const bm = std.fmt.bufPrint(&b, "{s}/BeeModel", .{home()}) catch home();
        goTo(if (isDir(bm)) bm else home());
        if (dir_len == 0) goTo("/");
    }
    suggested_len = @min(suggested.len, suggested_buf.len);
    @memcpy(suggested_buf[0..suggested_len], suggested[0..suggested_len]);
    app.dirty = true;
}

pub fn close() void {
    open_ = false;
    app.dirty = true;
}

fn isDir(path: []const u8) bool {
    var pb: [520]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

fn remember(d: []const u8) void {
    // the folder goes first in the recent ones
    var k: usize = 0;
    while (k < recent.len and !(recent_len[k] == d.len and std.mem.eql(u8, recent[k][0..recent_len[k]], d))) k += 1;
    if (k == recent.len) k = recent.len - 1;
    while (k > 0) : (k -= 1) {
        recent[k] = recent[k - 1];
        recent_len[k] = recent_len[k - 1];
    }
    const n = @min(d.len, recent[0].len);
    @memcpy(recent[0][0..n], d[0..n]);
    recent_len[0] = n;
}

// --- the disk, through BeeModel's own system calls ------------------------------------

const Disk = struct {
    fn source(self: *Disk) files.Source {
        return .{ .context = self, .listFn = list, .readFn = read, .existsFn = exists };
    }

    fn list(_: *anyopaque, path: []const u8, out: files.Listing) anyerror!void {
        var pb: [520]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&pb, "{s}", .{if (path.len == 0) "/" else path}, 0);
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.CannotOpen;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [16384]u8 align(8) = undefined;
        var count: usize = 0;
        while (true) {
            const n = linux.getdents64(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
                const nm_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
                const nm = std.mem.span(nm_ptr);
                off += d.reclen;
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                if (count >= 20000) continue; // (a folder of very many: its first)
                var st: linux.Statx = undefined;
                const ok = linux.errno(linux.statx(fd, nm_ptr, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &st)) == .SUCCESS;
                const is_dir = if (ok) st.mode & linux.S.IFMT == linux.S.IFDIR else d.type == linux.DT.DIR;
                try out.add(nm, is_dir, if (ok) st.size else 0, if (ok) st.mtime.sec else 0);
                count += 1;
            }
        }
    }

    fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        var pb: [600]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0);
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.CannotOpen;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var chunk: [65536]u8 = undefined;
        while (out.items.len < limit) {
            const n = linux.read(fd, &chunk, @min(chunk.len, limit - out.items.len));
            if (linux.errno(n) != .SUCCESS) return error.CannotRead;
            if (n == 0) break;
            try out.appendSlice(gpa, chunk[0..n]);
        }
        return out.toOwnedSlice(gpa);
    }

    fn exists(_: *anyopaque, path: []const u8) bool {
        var pb: [600]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return false;
        var st: linux.Statx = undefined;
        return linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .{ .TYPE = true }, &st)) == .SUCCESS;
    }
};

// --- the dialog --------------------------------------------------------------------------

/// The browser as a host client: modal, as the dialogs.
pub const client: host.Client = .{
    .visible = shown,
    .describe = describe,
    .modal = true,
};

fn shown() bool {
    return open_;
}

/// The extensions asked for ("one", or "several with spaces between").
var ext_list: [8][]const u8 = undefined;
var kind_name: [96]u8 = undefined;

fn kinds() [1]files.Kind {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, ext, ' ');
    while (it.next()) |e| {
        if (n == ext_list.len) break;
        ext_list[n] = e;
        n += 1;
    }
    var w = std.Io.Writer.fixed(&kind_name);
    // "STEP (.step .stp)": the kind named by the dialog's title, as it can
    var nm = title;
    for ([_][]const u8{ "Import ", "Export ", "Save " }) |pre| {
        if (std.mem.startsWith(u8, nm, pre)) nm = nm[pre.len..];
    }
    nm = std.mem.trimEnd(u8, nm, ". ");
    if (std.mem.indexOfScalar(u8, nm, '(')) |c| nm = std.mem.trimEnd(u8, nm[0..c], " ");
    if (std.mem.eql(u8, ext, ".bee")) nm = "BeeModel scenes";
    w.print("{s} ({s})", .{ if (nm.len > 0 and nm.len < 40) nm else "Files", ext }) catch {};
    return .{.{ .name = w.buffered(), .extensions = ext_list[0..n] }};
}

fn optionsPanel(_: ?*anyopaque, z: *zui.Ui) void {
    _ = z.checkbox("Selected objects only", &opt_sel, .{});
    if (!export_axis) return;
    z.label("Up axis", .{ .color = host.col(ui.th.text_dim) });
    z.beginHorizontal(.{ .spacing = 4 });
    if (z.button("Y", .{ .width = .px(34), .variant = if (!opt_zup) .selected else .normal }).clicked) opt_zup = false;
    if (z.button("Z", .{ .width = .px(34), .variant = if (opt_zup) .selected else .normal }).clicked) opt_zup = true;
    z.endHorizontal();
    z.label("Scale", .{ .color = host.col(ui.th.text_dim) });
    _ = z.numberField("##scale", &opt_scale, .{ .min = 0.0001, .max = 10000, .width = .px(110) });
}

// A .bee file's own picture (its THMB chunk), for the preview.
var th_px: [@import("thumb.zig").TW * @import("thumb.zig").TH]u32 = undefined;
var th_img: zui.Image = undefined;
var th_path: [600]u8 = undefined;
var th_len: usize = 0;
var th_ok = false;

fn thumbnail(_: ?*anyopaque, path: []const u8) ?*const zui.Image {
    if (!std.ascii.endsWithIgnoreCase(path, ".bee")) return null;
    if (!(th_len == path.len and std.mem.eql(u8, th_path[0..th_len], path))) {
        th_len = @min(path.len, th_path.len);
        @memcpy(th_path[0..th_len], path[0..th_len]);
        const t = @import("thumb.zig");
        th_ok = t.read(path, &th_px);
        if (th_ok) {
            for (&th_px) |*p| p.* |= 0xff000000;
            th_img = .initArgb(&th_px, t.TW, t.TH);
        }
    }
    return if (th_ok) &th_img else null;
}

var dlg_open = true;

fn describe(z: *zui.Ui) void {
    const b = blk: {
        if (browser == null) browser = files.Browser.init(host.allocator(), src.source(), dir()) catch return;
        break :blk &browser.?;
    };
    if (opening) {
        opening = false;
        b.go(dir());
        b.selected.clearRetainingCapacity();
        b.filter_len = 0;
        b.confirm_overwrite = false;
        b.message_len = 0;
        b.kind = 0;
        b.name_len = @min(suggested_len, b.name.len);
        @memcpy(b.name[0..b.name_len], suggested_buf[0..b.name_len]);
        if (mode == .save) z.setFocus(z.id("File name"));
    }
    dlg_open = true;
    const w: f32 = @floatFromInt(@min(860, app.winW() - 40));
    const h: f32 = @floatFromInt(@min(500, app.winH() - 120));
    if (!z.beginDialog(title, &dlg_open, .{ .min_width = w })) return;
    defer z.endDialog();
    var hb: [300]u8 = undefined;
    const bm = std.fmt.bufPrint(&hb, "{s}/BeeModel", .{home()}) catch home();
    const places = [_]files.Place{
        .{ .name = "Home", .path = home(), .icon = host.icon(.scene) },
        .{ .name = "BeeModel", .path = bm, .icon = host.icon(.folder) },
        .{ .name = "Computer", .path = "/", .icon = host.icon(.folder_open) },
    };
    var rec: [6][]const u8 = undefined;
    var nr: usize = 0;
    for (0..recent.len) |k| {
        if (recent_len[k] == 0) break;
        rec[nr] = recent[k][0..recent_len[k]];
        nr += 1;
    }
    const ks = kinds();
    const opts: files.Options = .{
        .mode = switch (mode) {
            .open => .open,
            .save => .save,
            .folder => .folder,
        },
        .kinds = &ks,
        .places = &places,
        .recent = rec[0..nr],
        .thumbnails = .{ .get = thumbnail },
        // (a folder: Open it, as BeeModel's browser said)
        .confirm = if (mode == .folder) "Open" else null,
        .panel = if (export_options) .{ .title = "Export", .draw = optionsPanel } else null,
    };
    z.beginVertical(.{ .width = .fill, .height = .px(h) });
    const r = files.fileBrowser(z, "##browser", b, opts);
    z.endVertical();
    // (Start there next time.)
    const n = @min(b.dir.items.len, dir_buf.len);
    @memcpy(dir_buf[0..n], b.dir.items[0..n]);
    dir_len = n;
    switch (r) {
        .none => if (!dlg_open) close(),
        .cancelled => close(),
        .chosen => |paths| {
            var keep: [600]u8 = undefined;
            const p = paths[0];
            const k = @min(p.len, keep.len);
            @memcpy(keep[0..k], p[0..k]);
            remember(dir());
            close();
            // (an export: its options, this once)
            if (export_options) @import("objmtl.zig").opts = .{ .sel_only = opt_sel, .zup = opt_zup, .scale = std.math.clamp(opt_scale, 0.0001, 10000) };
            on_done(keep[0..k]);
        },
    }
}
