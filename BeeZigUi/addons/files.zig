//! zui_files: a ready-made open and save browser.
//!
//! Built only on Zui's public API. Place it anywhere, usually in a dialog:
//!
//!     var disk: files.DiskSource = .{ .io = io };
//!     var browser: files.Browser = try .init(gpa, disk.source(), "/home/me");
//!     defer browser.deinit();
//!     ...
//!     if (ui.beginDialog("Export", &exporting, .{ .width = 900 })) {
//!         defer ui.endDialog();
//!         switch (files.fileBrowser(ui, "export", &browser, .{ .mode = .save, .kinds = &.{.{ .name = "glTF", .extensions = &.{".glb"} }} })) {
//!             .chosen => |paths| exportTo(paths[0]),
//!             .cancelled => exporting = false,
//!             .none => {},
//!         }
//!     }
//!
//! A list with name, size and date columns (click a column to sort),
//! folders first; a filter; hidden files with Ctrl+H; only the kinds asked
//! for, or all files. Crumbs, back, forward and up; Ctrl+L or a click on
//! the crumbs' end edits the path, Tab completes it. Places, favourites and
//! drives (with free space) and recent folders, all from the app. A
//! preview of PNG images, or the app's own thumbnails. Saving over a file
//! asks first; the app can add an options panel (export settings).
//! Keys: Enter opens, Backspace goes up, Alt+Left / Right go back and
//! forward.

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const Ui = zui.Ui;
const Rect = zui.Rect;
const Vec2 = zui.Vec2;
const Color = zui.Color;
const Allocator = std.mem.Allocator;

/// One file or folder of a listing.
pub const Entry = struct {
    name_start: u32,
    name_len: u32,
    dir: bool,
    size: u64,
    /// Seconds since 1970, UTC.
    mtime: i64,
};

/// A listing being filled by a `Source`.
pub const Listing = struct {
    gpa: Allocator,
    entries: *std.ArrayList(Entry),
    names: *std.ArrayList(u8),

    /// Adds one entry.
    pub fn add(self: Listing, name: []const u8, dir: bool, size: u64, mtime: i64) Allocator.Error!void {
        const start: u32 = @intCast(self.names.items.len);
        try self.names.appendSlice(self.gpa, name);
        try self.entries.append(self.gpa, .{ .name_start = start, .name_len = @intCast(name.len), .dir = dir, .size = size, .mtime = mtime });
    }
};

/// Where files come from: the disk (`DiskSource`), or anything else that
/// can list a folder and read a file (an archive, a test's fake tree).
pub const Source = struct {
    context: *anyopaque,
    /// Lists the folder at the absolute `path`.
    listFn: *const fn (context: *anyopaque, path: []const u8, out: Listing) anyerror!void,
    /// Reads at most `limit` bytes of the file at `path`.
    readFn: *const fn (context: *anyopaque, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8,
    /// Whether something exists at `path`.
    existsFn: *const fn (context: *anyopaque, path: []const u8) bool,
};

/// The disk, through `std.Io`.
pub const DiskSource = struct {
    io: std.Io,

    /// The interface for `Browser.init`.
    pub fn source(self: *DiskSource) Source {
        return .{ .context = self, .listFn = list, .readFn = read, .existsFn = exists };
    }

    fn list(context: *anyopaque, path: []const u8, out: Listing) anyerror!void {
        const self: *DiskSource = @ptrCast(@alignCast(context));
        const io = self.io;
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            const st = dir.statFile(io, e.name, .{}) catch null;
            const is_dir = e.kind == .directory or (if (st) |s| s.kind == .directory else false);
            const size: u64 = if (st) |s| s.size else 0;
            const mtime: i64 = if (st) |s| @intCast(@divFloor(s.mtime.nanoseconds, std.time.ns_per_s)) else 0;
            try out.add(e.name, is_dir, size, mtime);
        }
    }

    fn read(context: *anyopaque, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        const self: *DiskSource = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(limit));
    }

    fn exists(context: *anyopaque, path: []const u8) bool {
        const self: *DiskSource = @ptrCast(@alignCast(context));
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }
};

/// What the browser is for.
pub const Mode = enum {
    /// Pick existing files.
    open,
    /// Name a file to write, in a folder.
    save,
    /// Pick a folder.
    folder,
};

/// A kind of file to show: "Images" with ".png" and ".jpg".
pub const Kind = struct {
    name: []const u8,
    /// With the dot, any case.
    extensions: []const []const u8,
};

/// A place in the sidebar.
pub const Place = struct {
    name: []const u8,
    path: []const u8,
    icon: zui.Icon = .{ .builtin = .folder },
    /// Free and total bytes, for drives; see `freeSpace`.
    free: ?u64 = null,
    total: ?u64 = null,
};

/// The app's thumbnails, for its own file types (BeeModel's .bee
/// pictures).
pub const Thumbnails = struct {
    context: ?*anyopaque = null,
    /// The picture for `path`, or null to fall back to Zui's own preview.
    get: *const fn (context: ?*anyopaque, path: []const u8) ?*const zui.Image,
};

/// A panel the app fills, beside the preview: export settings.
pub const Panel = struct {
    title: []const u8 = "Options",
    context: ?*anyopaque = null,
    draw: *const fn (context: ?*anyopaque, ui: *Ui) void,
};

/// Options for `fileBrowser`.
pub const Options = struct {
    mode: Mode = .open,
    /// The kinds to show; "All files" is offered after them.
    kinds: []const Kind = &.{},
    /// Allow picking several files (open mode).
    multiple: bool = false,
    places: []const Place = &.{},
    favourites: []const Place = &.{},
    drives: []const Place = &.{},
    /// Recent folders, newest first, kept by the app.
    recent: []const []const u8 = &.{},
    thumbnails: ?Thumbnails = null,
    panel: ?Panel = null,
    /// The confirm button's text; "Open", "Save" or "Choose" by default.
    confirm: ?[]const u8 = null,
};

/// What the browser did this frame.
pub const Result = union(enum) {
    none,
    /// Cancel or Escape.
    cancelled,
    /// The chosen absolute paths, valid until the next `fileBrowser`.
    chosen: []const []const u8,
};

/// How the list is sorted.
pub const SortColumn = enum { name, size, date };

const Preview = struct {
    path: std.ArrayList(u8) = .empty,
    pixels: []u32 = &.{},
    image: ?zui.Image = null,
    width: u32 = 0,
    height: u32 = 0,
};

/// The browser's state, kept by the app.
pub const Browser = struct {
    gpa: Allocator,
    source: Source,
    /// The folder shown, absolute.
    dir: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// Entries shown, in order.
    rows: std.ArrayList(u32) = .empty,
    selected: std.ArrayList(bool) = .empty,
    list: zui.ListState = .{},
    back: std.ArrayList([]u8) = .empty,
    forward: std.ArrayList([]u8) = .empty,
    sort: SortColumn = .name,
    ascending: bool = true,
    /// Show files whose names start with a dot.
    hidden: bool = false,
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    filter_shown: [64]u8 = undefined,
    filter_shown_len: usize = 0,
    /// Which of the kinds; the last is "All files".
    kind: usize = 0,
    kind_shown: usize = std.math.maxInt(usize),
    hidden_shown: bool = false,
    /// The file name field, in save mode.
    name: [256]u8 = undefined,
    name_len: usize = 0,
    path_text: [max_path]u8 = undefined,
    path_len: usize = 0,
    editing_path: bool = false,
    focus_path: bool = false,
    message: [192]u8 = undefined,
    message_len: usize = 0,
    /// Saving over this file waits for a yes.
    confirm_overwrite: bool = false,
    /// The folder needs listing again.
    stale: bool = true,
    chosen: std.ArrayList(u8) = .empty,
    chosen_paths: std.ArrayList([]const u8) = .empty,
    preview: Preview = .{},

    /// A browser showing `start` (absolute).
    pub fn init(gpa: Allocator, source: Source, start: []const u8) Allocator.Error!Browser {
        var b: Browser = .{ .gpa = gpa, .source = source };
        try b.dir.appendSlice(gpa, start);
        return b;
    }

    /// Frees all memory.
    pub fn deinit(self: *Browser) void {
        const gpa = self.gpa;
        self.dir.deinit(gpa);
        self.entries.deinit(gpa);
        self.names.deinit(gpa);
        self.rows.deinit(gpa);
        self.selected.deinit(gpa);
        for (self.back.items) |p| gpa.free(p);
        self.back.deinit(gpa);
        for (self.forward.items) |p| gpa.free(p);
        self.forward.deinit(gpa);
        self.chosen.deinit(gpa);
        self.chosen_paths.deinit(gpa);
        self.preview.path.deinit(gpa);
        gpa.free(self.preview.pixels);
    }

    /// The name of entry `e`.
    pub fn nameOf(self: *const Browser, e: Entry) []const u8 {
        return self.names.items[e.name_start..][0..e.name_len];
    }

    /// Goes to the folder at `path` (absolute), remembering where it was
    /// for Back.
    pub fn go(self: *Browser, path: []const u8) void {
        if (std.mem.eql(u8, path, self.dir.items)) return;
        const old = self.gpa.dupe(u8, self.dir.items) catch return;
        self.back.append(self.gpa, old) catch {
            self.gpa.free(old);
            return;
        };
        for (self.forward.items) |p| self.gpa.free(p);
        self.forward.clearRetainingCapacity();
        self.setDir(path);
    }

    fn setDir(self: *Browser, path: []const u8) void {
        var clean: [max_path]u8 = undefined;
        const p = normalize(path, &clean);
        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(self.gpa, p) catch {};
        self.stale = true;
        self.list = .{};
    }

    /// Back to the previous folder.
    pub fn goBack(self: *Browser) void {
        const p = self.back.pop() orelse return;
        defer self.gpa.free(p);
        const here = self.gpa.dupe(u8, self.dir.items) catch return;
        self.forward.append(self.gpa, here) catch self.gpa.free(here);
        self.setDir(p);
    }

    /// Forward again, after Back.
    pub fn goForward(self: *Browser) void {
        const p = self.forward.pop() orelse return;
        defer self.gpa.free(p);
        const here = self.gpa.dupe(u8, self.dir.items) catch return;
        self.back.append(self.gpa, here) catch self.gpa.free(here);
        self.setDir(p);
    }

    /// Up to the folder that holds this one.
    pub fn goUp(self: *Browser) void {
        const parent = std.fs.path.dirname(self.dir.items) orelse return;
        var buffer: [max_path]u8 = undefined;
        if (parent.len > buffer.len) return;
        @memcpy(buffer[0..parent.len], parent);
        self.go(buffer[0..parent.len]);
    }

    fn say(self: *Browser, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&self.message, fmt, args) catch "";
        self.message_len = text.len;
    }

    /// Lists the folder again: after a change on disk, or a new filter.
    pub fn refresh(self: *Browser) void {
        self.stale = true;
    }

    fn relist(self: *Browser, options: Options) void {
        self.entries.clearRetainingCapacity();
        self.names.clearRetainingCapacity();
        self.message_len = 0;
        self.source.listFn(self.source.context, self.dir.items, .{ .gpa = self.gpa, .entries = &self.entries, .names = &self.names }) catch |err| {
            self.say("Can't open this folder: {s}", .{@errorName(err)});
        };
        self.stale = false;
        self.reorder(options);
    }

    /// Filters and sorts the entries into `rows`, keeping the selection by
    /// name where it can.
    fn reorder(self: *Browser, options: Options) void {
        var keep: ?[]const u8 = null;
        for (self.rows.items, 0..) |r, i| if (i < self.selected.items.len and self.selected.items[i]) {
            if (r < self.entries.items.len) keep = self.nameOf(self.entries.items[r]);
            break;
        };
        var keep_buffer: [256]u8 = undefined;
        if (keep) |k| {
            const n = @min(k.len, keep_buffer.len);
            @memcpy(keep_buffer[0..n], k[0..n]);
            keep = keep_buffer[0..n];
        }
        self.rows.clearRetainingCapacity();
        const filter = self.filter[0..self.filter_len];
        const kinds = options.kinds;
        const all = self.kind >= kinds.len;
        for (self.entries.items, 0..) |e, i| {
            const n = self.nameOf(e);
            if (!self.hidden and n.len > 0 and n[0] == '.') continue;
            if (filter.len > 0 and std.ascii.findIgnoreCase(n, filter) == null) continue;
            if (!e.dir) {
                if (options.mode == .folder) continue;
                if (!all and !matchesKind(n, kinds[self.kind])) continue;
            }
            self.rows.append(self.gpa, @intCast(i)) catch return;
        }
        const Ctx = struct {
            b: *const Browser,
            fn less(ctx: @This(), a: u32, c: u32) bool {
                const ea = ctx.b.entries.items[a];
                const ec = ctx.b.entries.items[c];
                // Folders first, whatever the column.
                if (ea.dir != ec.dir) return ea.dir;
                const order: std.math.Order = switch (ctx.b.sort) {
                    .name => naturalOrder(ctx.b.nameOf(ea), ctx.b.nameOf(ec)),
                    .size => std.math.order(ea.size, ec.size),
                    .date => std.math.order(ea.mtime, ec.mtime),
                };
                const o = if (order == .eq) naturalOrder(ctx.b.nameOf(ea), ctx.b.nameOf(ec)) else order;
                return if (ctx.b.ascending or order == .eq) o == .lt else o == .gt;
            }
        };
        std.mem.sort(u32, self.rows.items, Ctx{ .b = self }, Ctx.less);
        self.selected.resize(self.gpa, self.rows.items.len) catch return;
        @memset(self.selected.items, false);
        if (keep) |k| for (self.rows.items, 0..) |r, i| {
            if (std.mem.eql(u8, self.nameOf(self.entries.items[r]), k)) {
                self.selected.items[i] = true;
                self.list.cursor = i;
                break;
            }
        };
        self.filter_shown_len = self.filter_len;
        @memcpy(self.filter_shown[0..self.filter_len], self.filter[0..self.filter_len]);
        self.kind_shown = self.kind;
        self.hidden_shown = self.hidden;
    }

    /// The entry on row `i`.
    pub fn rowEntry(self: *const Browser, i: usize) Entry {
        return self.entries.items[self.rows.items[i]];
    }

    fn join(self: *Browser, name: []const u8, out: []u8) []const u8 {
        const dir = self.dir.items;
        const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
        return std.fmt.bufPrint(out, "{s}{s}{s}", .{ dir, sep, name }) catch out[0..0];
    }

    fn finish(self: *Browser, paths: []const []const u8) Result {
        self.chosen.clearRetainingCapacity();
        self.chosen_paths.clearRetainingCapacity();
        var total: usize = 0;
        for (paths) |p| total += p.len;
        self.chosen.ensureTotalCapacity(self.gpa, total) catch return .none;
        for (paths) |p| {
            const start = self.chosen.items.len;
            self.chosen.appendSliceAssumeCapacity(p);
            self.chosen_paths.append(self.gpa, self.chosen.items[start..]) catch return .none;
        }
        return .{ .chosen = self.chosen_paths.items };
    }
};

/// The longest path the browser handles: Linux's PATH_MAX.
const max_path = 4096;

/// "a/b/../c/" becomes "a/c"; keeps a lone "/".
fn normalize(path: []const u8, out: *[max_path]u8) []const u8 {
    // (a path of max_path bytes has at most half as many parts)
    var parts: [max_path / 2][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            n -|= 1;
            continue;
        }
        if (n < parts.len) {
            parts[n] = part;
            n += 1;
        }
    }
    var w: std.Io.Writer = .fixed(out);
    if (n == 0) return "/";
    for (parts[0..n]) |p| w.print("/{s}", .{p}) catch break;
    return out[0..w.end];
}

fn matchesKind(name: []const u8, kind: Kind) bool {
    for (kind.extensions) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Compares names as people expect: "img2" before "img10", any case.
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ei = i;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = j;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            const na = std.mem.trimStart(u8, a[i..ei], "0");
            const nb = std.mem.trimStart(u8, b[j..ej], "0");
            if (na.len != nb.len) return std.math.order(na.len, nb.len);
            const o = std.mem.order(u8, na, nb);
            if (o != .eq) return o;
            i = ei;
            j = ej;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

/// "12.3 KB".
pub fn formatSize(buffer: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1000 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ v, units[u] }) catch "";
}

/// "2026-11-07 14:05", UTC.
pub fn formatDate(buffer: []u8, seconds: i64) []const u8 {
    if (seconds <= 0) return "";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}

/// Free and total bytes of the file system holding `path`, where the
/// system can tell (Linux); null elsewhere.
pub fn freeSpace(path: []const u8) ?struct { free: u64, total: u64 } {
    if (builtin.os.tag != .linux) return null;
    var z: [max_path]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    // struct statfs on 64-bit Linux: type, bsize, blocks, bfree, bavail...
    var buf: [16]u64 align(8) = @splat(0);
    const linux = std.os.linux;
    const rc = linux.syscall2(.statfs, @intFromPtr(&z), @intFromPtr(&buf));
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .free = buf[4] * buf[1], .total = buf[2] * buf[1] };
}

/// The image `bytes` hold, if they are a PNG this decoder reads: 8-bit
/// grey, grey with alpha, RGB, RGBA or palette, not interlaced. Pixels are
/// `0xAARRGGBB`, owned by the caller.
pub fn decodePng(gpa: Allocator, bytes: []const u8) !struct { pixels: []u32, width: u32, height: u32 } {
    const signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], signature)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var palette: [256]u32 = @splat(0xFF000000);
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadHeader;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            const depth = data[8];
            color_type = data[9];
            if (depth != 8 or data[12] != 0) return error.Unsupported;
            if (width == 0 or height == 0 or @as(u64, width) * height > 64 << 20) return error.TooBig;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            var i: usize = 0;
            while (i * 3 + 2 < len and i < 256) : (i += 1) {
                palette[i] = 0xFF000000 | @as(u32, data[i * 3]) << 16 | @as(u32, data[i * 3 + 1]) << 8 | data[i * 3 + 2];
            }
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            for (data[0..@min(len, 256)], 0..) |a, i| palette[i] = (palette[i] & 0x00FFFFFF) | @as(u32, a) << 24;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    const channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    const stride = @as(usize, width) * channels;
    const raw_len = (stride + 1) * height;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    var reader: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    inflate.reader.readSliceAll(raw) catch return error.BadData;

    // Undo the filters, row by row.
    const out = try gpa.alloc(u32, @as(usize, width) * height);
    errdefer gpa.free(out);
    const prev = try gpa.alloc(u8, stride);
    defer gpa.free(prev);
    @memset(prev, 0);
    for (0..height) |y| {
        const row = raw[y * (stride + 1) ..][0 .. stride + 1];
        const filter = row[0];
        const cur = row[1..];
        for (cur, 0..) |*c, i| {
            const a: u8 = if (i >= channels) cur[i - channels] else 0;
            const b = prev[i];
            const cc: u8 = if (i >= channels) prev[i - channels] else 0;
            c.* = switch (filter) {
                0 => c.*,
                1 => c.* +% a,
                2 => c.* +% b,
                3 => c.* +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => c.* +% paeth(a, b, cc),
                else => return error.BadData,
            };
        }
        @memcpy(prev, cur);
        for (0..width) |x| {
            const p = cur[x * channels ..];
            out[y * width + x] = switch (color_type) {
                0 => 0xFF000000 | @as(u32, p[0]) * 0x010101,
                2 => 0xFF000000 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2],
                3 => palette[p[0]],
                4 => @as(u32, p[1]) << 24 | @as(u32, p[0]) * 0x010101,
                else => @as(u32, p[3]) << 24 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2],
            };
        }
    }
    return .{ .pixels = out, .width = width, .height = height };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn iconFor(e: Entry, name: []const u8) zui.Icon {
    if (e.dir) return .{ .builtin = .folder };
    const images = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".exr", ".hdr" };
    for (images) |ext| if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return .{ .builtin = .image };
    return .{ .builtin = .file };
}

const size_w = 86;
const date_w = 132;

/// The browser `name`, filling the space it gets. Returns what the user
/// did this frame.
pub fn fileBrowser(ui: *Ui, name: []const u8, b: *Browser, options: Options) Result {
    ui.pushId(name);
    defer ui.popId();
    const in = &ui.input;
    var result: Result = .none;
    if (b.stale) b.relist(options);
    if (b.filter_len != b.filter_shown_len or !std.mem.eql(u8, b.filter[0..b.filter_len], b.filter_shown[0..b.filter_shown_len]) or b.kind != b.kind_shown or b.hidden != b.hidden_shown) b.reorder(options);

    // Keys, unless a text field has them.
    const Shortcut = zui.Shortcut;
    const typing = ui.wantsKeyboard();
    if ((Shortcut{ .key = .h, .modifiers = .{ .ctrl = true } }).pressed(in)) b.hidden = !b.hidden;
    if ((Shortcut{ .key = .l, .modifiers = .{ .ctrl = true } }).pressed(in)) startPathEdit(b);
    if ((Shortcut{ .key = .left, .modifiers = .{ .alt = true } }).pressed(in)) b.goBack();
    if ((Shortcut{ .key = .right, .modifiers = .{ .alt = true } }).pressed(in)) b.goForward();
    if ((Shortcut{ .key = .up, .modifiers = .{ .alt = true } }).pressed(in)) b.goUp();
    if (!typing and (Shortcut{ .key = .backspace }).pressed(in)) b.goUp();

    toolbar(ui, b, options);

    ui.beginHorizontal(.{ .height = .fill, .alignment = .start });
    sidebar(ui, b, options);
    // The list.
    ui.beginVertical(.{ .width = .fill, .height = .fill });
    if (listing(ui, b, options)) |r| result = r;
    ui.beginHorizontal(.{});
    _ = ui.textInput("##filter", &b.filter, &b.filter_len, .{ .width = .fill, .hint = "Filter by name" });
    var kinds: [17]zui.Choice = undefined;
    const nk = @min(options.kinds.len, kinds.len - 1);
    if (options.mode != .folder) {
        for (options.kinds[0..nk], 0..) |k, i| kinds[i] = .{ .label = k.name };
        kinds[nk] = .{ .label = "All files" };
        if (b.kind > nk) b.kind = nk;
        _ = ui.dropdown("##kind", &b.kind, kinds[0 .. nk + 1], .{});
    }
    ui.endHorizontal();
    ui.endVertical();
    side(ui, b, options);
    ui.endHorizontal();

    if (b.message_len > 0) ui.label(b.message[0..b.message_len], .{ .color = ui.style.colors.warning });
    if (bottom(ui, b, options)) |r| result = r;
    return result;
}

fn startPathEdit(b: *Browser) void {
    b.editing_path = true;
    b.focus_path = true;
    const n = @min(b.dir.items.len, b.path_text.len);
    @memcpy(b.path_text[0..n], b.dir.items[0..n]);
    b.path_len = n;
}

fn toolbar(ui: *Ui, b: *Browser, options: Options) void {
    _ = options;
    ui.beginHorizontal(.{});
    ui.pushDisabled(if (b.back.items.len == 0) "Nothing to go back to" else null);
    if (ui.button("##Back", .{ .icon = .{ .builtin = .arrow_left } }).clicked) b.goBack();
    ui.popDisabled();
    ui.pushDisabled(if (b.forward.items.len == 0) "Nothing to go forward to" else null);
    if (ui.button("##Forward", .{ .icon = .{ .builtin = .arrow_right } }).clicked) b.goForward();
    ui.popDisabled();
    ui.pushDisabled(if (std.mem.eql(u8, b.dir.items, "/")) "This is the top" else null);
    if (ui.button("##Up", .{ .icon = .{ .builtin = .arrow_up } }).clicked) b.goUp();
    ui.popDisabled();
    if (ui.button("##Refresh", .{ .icon = .{ .builtin = .refresh } }).clicked) b.refresh();

    if (b.editing_path) {
        const field = ui.id("Path");
        if (b.focus_path) {
            ui.setFocus(field);
            b.focus_path = false;
        }
        // Tab completes the path rather than moving on.
        if (ui.focused == field) {
            ui.tab_owner = field;
            for (ui.input.keyEvents()) |e| if (e.key == .tab and !e.modifiers.shift) completePath(ui, b);
        }
        const t = ui.textInput("Path", &b.path_text, &b.path_len, .{ .width = .fill, .hint = "/path/to/folder" });
        if (t.submitted) {
            // A path not starting with / goes from the folder shown.
            var full: [max_path]u8 = undefined;
            const typed = b.path_text[0..b.path_len];
            const whole = if (typed.len > 0 and typed[0] == '/') typed else b.join(typed, &full);
            var clean: [max_path]u8 = undefined;
            const p = normalize(whole, &clean);
            if (typed.len > 0) {
                if (b.source.existsFn(b.source.context, p)) {
                    b.go(p);
                    b.editing_path = false;
                } else b.say("No such folder: {s}", .{p});
            }
        } else if (t.cancelled or (!t.focused and !t.started and ui.focused != field)) {
            b.editing_path = false;
        }
    } else {
        // Crumbs: one button per folder on the way, the last few of a long
        // path, after a "..." that goes to the one before them.
        var count: usize = 0;
        var counter = std.mem.tokenizeScalar(u8, b.dir.items, '/');
        while (counter.next()) |_| count += 1;
        const max_crumbs = 4;
        var it = std.mem.tokenizeScalar(u8, b.dir.items, '/');
        var end: usize = 0;
        if (ui.button("/##crumb root", .{}).clicked) b.go("/");
        var i: u64 = 0;
        if (count > max_crumbs) {
            while (i < count - max_crumbs) : (i += 1) {
                const part = it.next().?;
                end = @intFromPtr(part.ptr) - @intFromPtr(b.dir.items.ptr) + part.len;
            }
            if (ui.button("...##crumbs", .{}).clicked) {
                var buffer: [max_path]u8 = undefined;
                const n = @min(end, buffer.len);
                @memcpy(buffer[0..n], b.dir.items[0..n]);
                b.go(buffer[0..n]);
            }
        }
        while (it.next()) |part| : (i += 1) {
            end = @intFromPtr(part.ptr) - @intFromPtr(b.dir.items.ptr) + part.len;
            ui.pushIdInt(i);
            const clicked = ui.button(part, .{}).clicked;
            ui.popId();
            if (clicked) {
                var buffer: [max_path]u8 = undefined;
                const n = @min(end, buffer.len);
                @memcpy(buffer[0..n], b.dir.items[0..n]);
                b.go(buffer[0..n]);
                break;
            }
        }
        // The rest of the row: click to type a path.
        const rest = ui.placeSized(.fill, .auto, .{ .x = 40, .y = ui.textSize("").y + 2 * ui.style.frame_padding.y });
        const r = ui.interact(ui.id("##edit path"), rest);
        if (r.hovered) ui.cursor = .text;
        ui.recordWidget(.button, r.id, "Edit path", rest, .{ .hovered = r.hovered });
        if (r.clicked) startPathEdit(b);
    }
    _ = ui.iconToggle("Hidden files", &b.hidden, .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off } });
    ui.endHorizontal();
}

/// Completes the last part of the typed path from the folder it is in:
/// as far as all matches agree, and a "/" for a single folder.
fn completePath(ui: *Ui, b: *Browser) void {
    // A copy: the result is written over the field's text.
    var copy: [max_path]u8 = undefined;
    const text = copy[0..b.path_len];
    @memcpy(text, b.path_text[0..b.path_len]);
    const cut = std.mem.lastIndexOfScalar(u8, text, '/') orelse return;
    const dir = if (cut == 0) "/" else text[0..cut];
    const prefix = text[cut + 1 ..];
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(b.gpa);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(b.gpa);
    b.source.listFn(b.source.context, dir, .{ .gpa = b.gpa, .entries = &entries, .names = &names }) catch return;
    var common: ?[]const u8 = null;
    var count: usize = 0;
    var only_dir = false;
    for (entries.items) |e| {
        const n = names.items[e.name_start..][0..e.name_len];
        if (!std.mem.startsWith(u8, n, prefix)) continue;
        if (!b.hidden and prefix.len == 0 and n.len > 0 and n[0] == '.') continue;
        count += 1;
        only_dir = e.dir;
        if (common) |c| {
            var k: usize = 0;
            while (k < @min(c.len, n.len) and c[k] == n[k]) k += 1;
            common = c[0..k];
        } else common = n;
    }
    const c = common orelse return;
    var w: std.Io.Writer = .fixed(&b.path_text);
    w.print("{s}{s}{s}{s}", .{ dir, if (dir.len > 1) "/" else "", c, if (count == 1 and only_dir) "/" else "" }) catch return;
    b.path_len = w.end;
    // The caret goes to the end of what was added.
    ui.text_edit.caret = b.path_len;
    ui.text_edit.anchor = b.path_len;
}

fn sidebar(ui: *Ui, b: *Browser, options: Options) void {
    // (scrolls: many drives and recent folders outgrow a short dialog)
    ui.beginScrollArea("##places", .{ .width = .px(190), .height = .fill, .frame = false, .padding = 0 });
    const muted = ui.style.colors.text_muted;
    const sections = [_]struct { []const u8, []const Place }{
        .{ "Places", options.places },
        .{ "Favourites", options.favourites },
        .{ "Drives", options.drives },
    };
    for (sections) |section| {
        const title, const places = section;
        if (places.len == 0) continue;
        ui.label(title, .{ .color = muted });
        ui.pushId(title);
        for (places, 0..) |p, i| {
            ui.pushIdInt(i);
            const here = std.mem.eql(u8, p.path, b.dir.items);
            if (ui.selectable(p.name, here, .{ .icon = p.icon }).clicked) b.go(p.path);
            if (p.free) |free| {
                var buffer: [64]u8 = undefined;
                var s1: [16]u8 = undefined;
                var s2: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} free of {s}", .{ formatSize(&s1, free), formatSize(&s2, p.total orelse free) }) catch "";
                ui.label(text, .{ .color = muted });
                if (p.total) |total| if (total > 0) {
                    ui.progressBar(1 - @as(f32, @floatFromInt(free)) / @as(f32, @floatFromInt(total)), .{});
                };
            }
            ui.popId();
        }
        ui.popId();
    }
    if (options.recent.len > 0) {
        ui.label("Recent", .{ .color = muted });
        ui.pushId("recent");
        for (options.recent, 0..) |p, i| {
            ui.pushIdInt(i);
            const base = std.fs.path.basename(p);
            if (ui.selectable(if (base.len > 0) base else p, std.mem.eql(u8, p, b.dir.items), .{ .icon = .{ .builtin = .folder } }).clicked) b.go(p);
            ui.popId();
        }
        ui.popId();
    }
    ui.endScrollArea();
}

fn listing(ui: *Ui, b: *Browser, options: Options) ?Result {
    var result: ?Result = null;
    const colors = &ui.style.colors;
    // Column titles: click to sort, again to reverse.
    ui.beginHorizontal(.{ .spacing = 0 });
    const columns = [_]struct { []const u8, SortColumn, zui.Size }{
        .{ "Name", .name, .fill },
        .{ "Size", .size, .{ .fixed = size_w } },
        .{ "Modified", .date, .{ .fixed = date_w + 12 } },
    };
    for (columns) |col| {
        const title, const which, const width = col;
        var buffer: [32]u8 = undefined;
        const arrow: []const u8 = if (b.sort == which) (if (b.ascending) " \u{25B2}" else " \u{25BC}") else "";
        const label = std.fmt.bufPrint(&buffer, "{s}{s}##{s}", .{ title, arrow, title }) catch title;
        if (ui.button(label, .{ .width = width }).clicked) {
            if (b.sort == which) b.ascending = !b.ascending else {
                b.sort = which;
                b.ascending = true;
            }
            b.reorder(options);
        }
    }
    ui.endHorizontal();

    var list = ui.beginList("Files", b.selected.items, &b.list, .{ .height = .fill });
    var open_dir: ?usize = null;
    var i = list.first;
    while (i < list.end) : (i += 1) {
        const e = b.rowEntry(i);
        const n = b.nameOf(e);
        ui.beginRow(&list, i, .{ .label = n, .icon = iconFor(e, n) });
        const r = list.row_rect;
        var buffer: [32]u8 = undefined;
        const line_h = ui.textSize("").y;
        const y = r.y + (r.h - line_h) / 2;
        if (!e.dir) {
            const s = formatSize(&buffer, e.size);
            ui.drawText(.{ .x = r.right() - date_w - 16 - ui.textSize(s).x, .y = y }, colors.text_muted, s);
        }
        const d = formatDate(&buffer, e.mtime);
        ui.drawText(.{ .x = r.right() - date_w, .y = y }, colors.text_muted, d);
        const row = ui.endRow(&list);
        if (row.interaction.clicked or row.interaction.pressed) {
            // A file click names it for saving.
            if (!e.dir and options.mode == .save) setName(b, n);
        }
        if (row.activated) {
            if (e.dir) {
                // Go there once the list is ended.
                open_dir = i;
            } else if (options.mode == .open) {
                result = confirm(b, options);
            } else if (options.mode == .save) {
                setName(b, n);
                result = confirm(b, options);
            }
        }
    }
    const lr = ui.endList(&list);
    if (open_dir) |d| {
        var p: [max_path]u8 = undefined;
        b.go(b.join(b.nameOf(b.rowEntry(d)), &p));
        return null;
    }
    if (lr.activated) |a| if (a < b.rows.items.len) {
        const e = b.rowEntry(a);
        const n = b.nameOf(e);
        if (e.dir) {
            var p: [max_path]u8 = undefined;
            const path = b.join(n, &p);
            b.go(path);
            return null;
        } else if (options.mode != .folder) {
            if (options.mode == .save) setName(b, n);
            result = confirm(b, options);
        }
    };
    if (lr.changed and options.mode == .save) {
        for (b.selected.items, 0..) |s, k| if (s) {
            const e = b.rowEntry(k);
            if (!e.dir) setName(b, b.nameOf(e));
            break;
        };
    }
    if (b.rows.items.len == 0 and b.message_len == 0) {
        const empty = lr.empty;
        const text = if (b.filter_len > 0) "Nothing matches the filter" else "This folder is empty";
        const tw = ui.textSize(text).x;
        ui.drawText(.{ .x = empty.x + (empty.w - tw) / 2, .y = empty.y + 20 }, colors.text_muted, text);
    }
    return result;
}

fn setName(b: *Browser, n: []const u8) void {
    const k = @min(n.len, b.name.len);
    @memcpy(b.name[0..k], n[0..k]);
    b.name_len = k;
}

/// The one selected file, if exactly one is.
fn singleFile(b: *const Browser) ?Entry {
    var found: ?Entry = null;
    for (b.selected.items, 0..) |s, i| if (s) {
        if (found != null) return null;
        found = b.rowEntry(i);
    };
    if (found) |e| if (e.dir) return null;
    return found;
}

fn side(ui: *Ui, b: *Browser, options: Options) void {
    ui.beginVertical(.{ .width = .px(220), .height = .fill });
    const colors = &ui.style.colors;
    ui.label("Preview", .{ .color = colors.text_muted });
    const box = ui.placeSized(.fill, .{ .fixed = 200 }, .{ .x = 200, .y = 200 });
    ui.drawRect(.{ .rect = box, .fill = colors.input, .border = colors.border, .border_width = 1, .radius = ui.style.rounding });
    if (singleFile(b)) |e| {
        const n = b.nameOf(e);
        var p: [max_path]u8 = undefined;
        const path = b.join(n, &p);
        var img: ?*const zui.Image = null;
        if (options.thumbnails) |t| img = t.get(t.context, path);
        if (img == null and matchesKind(n, .{ .name = "", .extensions = &.{".png"} })) {
            loadPreview(b, path);
            if (b.preview.image) |*i| img = i;
        }
        if (img) |i| {
            const iw: f32 = @floatFromInt(i.width);
            const ih: f32 = @floatFromInt(i.height);
            const k = @min((box.w - 12) / iw, (box.h - 12) / ih, 1.0 * 8);
            const w = iw * k;
            const h = ih * k;
            const r: Rect = .{ .x = box.x + (box.w - w) / 2, .y = box.y + (box.h - h) / 2, .w = w, .h = h };
            ui.painter().image(i, r, .{ .filter = if (k >= 2) .nearest else .linear });
            ui.recordWidget(.custom, .none, "preview", r, .{ .value = n });
            ui.labelf("{d} \u{00D7} {d}", .{ i.width, i.height }, .{ .color = colors.text_muted });
        } else {
            const s: f32 = 64;
            ui.painter().icon(iconFor(e, n), .{ .x = box.x + (box.w - s) / 2, .y = box.y + (box.h - s) / 2, .w = s, .h = s }, colors.text_muted);
        }
        var buffer: [32]u8 = undefined;
        ui.wrappedText(n, .{});
        ui.label(formatSize(&buffer, e.size), .{ .color = colors.text_muted });
        ui.label(formatDate(&buffer, e.mtime), .{ .color = colors.text_muted });
    } else {
        var count: usize = 0;
        for (b.selected.items) |s| count += @intFromBool(s);
        if (count > 1) ui.labelf("{d} selected", .{count}, .{ .color = colors.text_muted });
    }
    if (options.panel) |panel| {
        ui.separator();
        ui.label(panel.title, .{ .color = colors.text_muted });
        panel.draw(panel.context, ui);
    }
    ui.endVertical();
}

fn loadPreview(b: *Browser, path: []const u8) void {
    if (std.mem.eql(u8, b.preview.path.items, path)) return;
    b.preview.path.clearRetainingCapacity();
    b.preview.path.appendSlice(b.gpa, path) catch return;
    b.gpa.free(b.preview.pixels);
    b.preview.pixels = &.{};
    b.preview.image = null;
    const bytes = b.source.readFn(b.source.context, b.gpa, path, 64 << 20) catch return;
    defer b.gpa.free(bytes);
    const decoded = decodePng(b.gpa, bytes) catch return;
    b.preview.pixels = decoded.pixels;
    b.preview.image = .initArgb(decoded.pixels, decoded.width, decoded.height);
}

fn bottom(ui: *Ui, b: *Browser, options: Options) ?Result {
    var result: ?Result = null;
    const colors = &ui.style.colors;
    if (b.confirm_overwrite) {
        ui.beginHorizontal(.{ .fill = colors.warning.withAlpha(40), .padding = 6 });
        ui.pushIdInt(0);
        ui.labelf("\"{s}\" already exists. Replace it?", .{b.name[0..b.name_len]}, .{ .color = colors.text });
        ui.spacer(.fill);
        if (ui.button("Replace", .{}).clicked) {
            b.confirm_overwrite = false;
            var p: [max_path]u8 = undefined;
            const path = b.join(b.name[0..b.name_len], &p);
            result = b.finish(&.{path});
        }
        if (ui.button("Keep It", .{}).clicked) b.confirm_overwrite = false;
        ui.popId();
        ui.endHorizontal();
    }
    ui.beginHorizontal(.{});
    var submitted = false;
    if (options.mode == .save) {
        const field = ui.textInput("File name", &b.name, &b.name_len, .{ .width = .fill, .hint = "Name the file" });
        submitted = field.submitted;
        if (field.changed) b.confirm_overwrite = false;
    } else {
        ui.spacer(.fill);
    }
    if (ui.button("Cancel", .{}).clicked) result = .cancelled;
    const label = options.confirm orelse switch (options.mode) {
        .open => "Open",
        .save => "Save",
        .folder => "Choose",
    };
    const why: ?[]const u8 = switch (options.mode) {
        .open => if (selectedFiles(b) == 0) "Select a file first" else null,
        .save => if (b.name_len == 0) "Type a file name first" else null,
        .folder => null,
    };
    ui.pushDisabled(why);
    const go = ui.button(label, .{});
    ui.popDisabled();
    ui.endHorizontal();
    if ((go.clicked or submitted) and why == null) result = confirm(b, options) orelse result;
    return result;
}

fn selectedFiles(b: *const Browser) usize {
    var n: usize = 0;
    for (b.selected.items, 0..) |s, i| if (s and !b.rowEntry(i).dir) {
        n += 1;
    };
    return n;
}

/// The confirm button: what it chooses, depending on the mode.
fn confirm(b: *Browser, options: Options) ?Result {
    switch (options.mode) {
        .open => {
            var paths: [64][]const u8 = undefined;
            const storage = b.gpa.alloc([max_path]u8, paths.len) catch return null;
            defer b.gpa.free(storage);
            var n: usize = 0;
            for (b.selected.items, 0..) |s, i| if (s and n < paths.len) {
                const e = b.rowEntry(i);
                if (e.dir) continue;
                paths[n] = b.join(b.nameOf(e), &storage[n]);
                n += 1;
                if (!options.multiple) break;
            };
            if (n == 0) return null;
            return b.finish(paths[0..n]);
        },
        .save => {
            if (b.name_len == 0) return null;
            // Add the kind's extension if the name has none of them.
            if (options.kinds.len > 0 and b.kind < options.kinds.len) {
                const kind = options.kinds[b.kind];
                if (!matchesKind(b.name[0..b.name_len], kind) and kind.extensions.len > 0) {
                    const ext = kind.extensions[0];
                    if (b.name_len + ext.len <= b.name.len) {
                        @memcpy(b.name[b.name_len..][0..ext.len], ext);
                        b.name_len += ext.len;
                    }
                }
            }
            var p: [max_path]u8 = undefined;
            const path = b.join(b.name[0..b.name_len], &p);
            if (b.source.existsFn(b.source.context, path) and !b.confirm_overwrite) {
                b.confirm_overwrite = true;
                return null;
            }
            b.confirm_overwrite = false;
            return b.finish(&.{path});
        },
        .folder => {
            var p: [max_path]u8 = undefined;
            for (b.selected.items, 0..) |s, i| if (s) {
                const e = b.rowEntry(i);
                if (e.dir) return b.finish(&.{b.join(b.nameOf(e), &p)});
            };
            return b.finish(&.{b.dir.items});
        },
    }
}

comptime {
    // Compile everything, also when built as an object for other systems.
    if (@import("builtin").output_mode == .Obj) {
        _ = &fileBrowser;
        _ = &freeSpace;
        _ = &decodePng;
        _ = &DiskSource;
    }
}

const testing = std.testing;

test "natural order, sizes, dates, paths" {
    try testing.expectEqual(std.math.Order.lt, naturalOrder("img2.png", "img10.png"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Apple", "banana"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("a01", "a1"));
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("512 B", formatSize(&buffer, 512));
    try testing.expectEqualStrings("12.3 KB", formatSize(&buffer, 12600));
    try testing.expectEqualStrings("1970-01-02 00:00", formatDate(&buffer, 86400));
    var out: [max_path]u8 = undefined;
    try testing.expectEqualStrings("/a/c", normalize("/a/b/../c/", &out));
    try testing.expectEqualStrings("/", normalize("/a/..", &out));
}
