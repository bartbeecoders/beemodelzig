// Reference images from a folder or a PDF (refset.s): a building's drawings
// sorted out and set up around the building to model over.
//
// object.add_references <folder | file.pdf | image> takes every PDF and image
// in the folder (not its sub-folders). PDFs are read by poppler, as in the
// original: pdfinfo counts the pages, pdftoppm draws each into a PNG (100 dpi),
// pdftotext reads its text, eight at a time, into
// ~/BeeModel/References/<the folder's name>/ (kept: the scene refers to them; a
// page is drawn again only when its PDF is newer). Each page is sorted out
// (refclass.zig) and comes in at its true size, into a folder of its own:
// "Refs <name>", elevations stood up facing their side, plans flat at 3 m a
// level with only the ground floor shown; sections, site, terrain profiles,
// other pages and every existing drawing in hidden folders.
//
// With the AI: it looks at the pages (MCP reference_view), sorts out the ones
// taken wrongly (object.reference_kind) and lines them up
// (object.reference_pin); object.references_ai asks it to.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const refimg = @import("refimg.zig");
const refclass = @import("refclass.zig");
const folders = @import("folders.zig");
const spawn = @import("spawn.zig");
const jobui = @import("jobui.zig");
const files = @import("files.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const images = @import("images.zig");
const Kind = refclass.Kind;

const RS_MAX = 160;
const MAXF = 512;
const JOBS = 8;
/// A poppler program on one page: past this it goes (a PDF can be made to hang it).
const JOB_MS = 120_000;
/// Pixels of drawings held at once: images are floats, a hundred A0 sheets
/// would take more memory than there is.
const MAX_PIXELS: u64 = 512_000_000;

const Page = struct {
    src: [512]u8 = undefined,
    src_len: u16 = 0,
    png: [640]u8 = undefined,
    png_len: u16 = 0,
    page: u32 = 0, // 1.. (0: an image file)
    npage: u32 = 0,
    c: refclass.Page = .{},
    guess: bool = false,
    obj: ?usize = null,
    shown: bool = false,
    fn srcS(p: *const Page) []const u8 {
        return p.src[0..p.src_len];
    }
    fn pngS(p: *const Page) []const u8 {
        return p.png[0..p.png_len];
    }
};

var tab: [RS_MAX]Page = undefined;
var n_pages: usize = 0;
var n_files: u32 = 0;
var skipped: u32 = 0;
var nopdf: u32 = 0;
var too_big: u32 = 0;
var pixels: u64 = 0;
var pids: [JOBS]i32 = undefined;
var n_jobs: usize = 0;
var tools = false;
var ppm_b: [512]u8 = undefined;
var ptt_b: [512]u8 = undefined;
var info_b: [512]u8 = undefined;
var ppm: [:0]const u8 = "";
var ptt: [:0]const u8 = "";
var pinfo: [:0]const u8 = "";
var dir_b: [600]u8 = undefined;
var dir: []const u8 = "";
var set_b: [128]u8 = undefined;
var set_name: []const u8 = "";
var stage0: f32 = 0;
var stage_n: f32 = 1;

fn stage(a: f32, b: f32) void {
    stage0 = a;
    stage_n = b;
    jobui.set(a);
}
fn pf(i: usize, n: usize) void {
    jobui.set(stage0 + stage_n * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(n, 1))));
}

/// 1 a PDF, 2 an image, 0 neither.
fn extKind(name: []const u8) u8 {
    const d = std.mem.lastIndexOfScalar(u8, name, '.') orelse return 0;
    const e = name[d + 1 ..];
    if (std.ascii.eqlIgnoreCase(e, "pdf")) return 1;
    for ([_][]const u8{ "png", "jpg", "jpeg", "hdr", "exr" }) |x| {
        if (std.ascii.eqlIgnoreCase(e, x)) return 2;
    }
    return 0;
}

fn stripExt(s: []const u8) []const u8 {
    const d = std.mem.lastIndexOfScalar(u8, s, '.') orelse return s;
    const sl = std.mem.lastIndexOfScalar(u8, s, '/');
    if (d == 0 or (sl != null and d < sl.?)) return s;
    return s[0..d];
}

const Stat = struct { mode: u32, mtime: i64 };

fn stat(path: []const u8) ?Stat {
    var b: [1024]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{path}, 0) catch return null;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true, .MTIME = true }, &st)) != .SUCCESS) return null;
    return .{ .mode = st.mode, .mtime = st.mtime.sec };
}

fn findTools() void {
    tools = false;
    ppm = spawn.which(&ppm_b, "pdftoppm") orelse return;
    ptt = spawn.which(&ptt_b, "pdftotext") orelse return;
    pinfo = spawn.which(&info_b, "pdfinfo") orelse return;
    tools = true;
}

fn toolsNote() void {
    if (nopdf > 0) app.log("  references: PDFs left out: {d} (they need poppler-utils: pdftoppm, pdftotext, pdfinfo)", .{nopdf});
}

/// set_name = the folder's name (a PDF's without .pdf), dir = ~/BeeModel/References/<it>.
fn makeDir(in: []const u8) bool {
    var base = std.fs.path.basename(in);
    if (extKind(base) != 0) base = stripExt(base);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) base = "Drawings";
    const n = @min(base.len, 100);
    @memcpy(set_b[0..n], base[0..n]);
    set_name = set_b[0..n];
    var eb: [700]u8 = undefined;
    const rel = std.fmt.bufPrint(&eb, "~/BeeModel/References/{s}", .{set_name}) catch return false;
    var pb: [1024]u8 = undefined;
    const p = files.expandHome(&pb, rel) orelse return false;
    if (p.len >= dir_b.len) return false;
    @memcpy(dir_b[0..p.len], p);
    dir = dir_b[0..p.len];
    return files.mayWrite(dir) and spawn.ensureDir(dir);
}

fn stdoutTo(path: [*:0]const u8) i32 {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    return if (linux.errno(rc) == .SUCCESS) @intCast(rc) else spawn.NULL;
}

fn pump() void {
    jobui.pump();
}

/// How many pages pdfinfo says (0: not a PDF it reads).
fn pdfPages(src: [:0]const u8) u32 {
    var ib: [700]u8 = undefined;
    const info = std.fmt.bufPrintSentinel(&ib, "{s}/.pdfinfo", .{dir}, 0) catch return 0;
    const av = [_:null]?[*:0]const u8{ pinfo.ptr, src.ptr };
    const fd = stdoutTo(info.ptr);
    const pid = spawn.spawn(pinfo.ptr, &av, spawn.KEEP, fd, spawn.NULL);
    if (fd >= 0) _ = linux.close(fd);
    const st = spawn.waitFor(pid orelse return 0, JOB_MS, pump) orelse return 0;
    if (st != 0) return 0;
    const raw = @import("ttf.zig").mapFile(info) orelse return 0;
    defer _ = linux.munmap(raw.ptr, raw.len);
    return pagesIn(raw[0..@min(raw.len, 8000)]);
}

/// The number after "Pages:" (saturating).
pub fn pagesIn(t: []const u8) u32 {
    const o = std.mem.indexOf(u8, t, "Pages:") orelse return 0;
    var i = o + 6;
    while (i < t.len and t[i] == ' ') i += 1;
    var v: u32 = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
        v = @min(v *| 10 +| (t[i] - '0'), 10_000_000);
    }
    return v;
}

fn newPage(src: []const u8, page: u32, pages: u32) ?*Page {
    if (n_pages >= RS_MAX) {
        if (skipped == 0) app.log("  references: 160 pages at most; the rest left out", .{});
        skipped += 1;
        return null;
    }
    const p = &tab[n_pages];
    n_pages += 1;
    p.* = .{};
    const n = @min(src.len, p.src.len - 1);
    @memcpy(p.src[0..n], src[0..n]);
    p.src_len = @intCast(n);
    p.page = page;
    p.npage = pages;
    return p;
}

/// One more poppler program, once fewer than JOBS of ours run.
fn job(argv: [*:null]const ?[*:0]const u8) void {
    if (n_jobs >= JOBS) {
        _ = spawn.waitFor(pids[0], JOB_MS, pump); // the oldest one first
        std.mem.copyForwards(i32, pids[0 .. JOBS - 1], pids[1..JOBS]);
        n_jobs -= 1;
    }
    const pid = spawn.spawn(argv[0].?, argv, spawn.KEEP, spawn.NULL, spawn.NULL) orelse return;
    pids[n_jobs] = pid;
    n_jobs += 1;
}

fn jobsEnd() void {
    for (pids[0..n_jobs]) |pid| _ = spawn.waitFor(pid, JOB_MS, pump);
    n_jobs = 0;
}

/// Its PNG named; the page drawn and its text read unless done since the PDF changed.
fn pageFiles(p: *Page, pdf_time: i64) void {
    var sb: [520]u8 = undefined;
    const src = std.fmt.bufPrintSentinel(&sb, "{s}", .{p.srcS()}, 0) catch return;
    var ob: [660]u8 = undefined;
    const base = stripExt(std.fs.path.basename(src));
    const stem = if (p.npage > 1)
        std.fmt.bufPrintSentinel(&ob, "{s}/{s}-p{d}", .{ dir, base[0..@min(base.len, 100)], p.page }, 0) catch return
    else
        std.fmt.bufPrintSentinel(&ob, "{s}/{s}", .{ dir, base[0..@min(base.len, 100)] }, 0) catch return;
    const png = std.fmt.bufPrint(&p.png, "{s}.png", .{stem}) catch return;
    p.png_len = @intCast(png.len);
    if (stat(png)) |st| {
        if (st.mtime >= pdf_time) return;
    }
    var nb: [16]u8 = undefined;
    const num = std.fmt.bufPrintSentinel(&nb, "{d}", .{p.page}, 0) catch return;
    const a1 = [_:null]?[*:0]const u8{ ppm.ptr, "-r", "100", "-png", "-singlefile", "-f", num.ptr, "-l", num.ptr, src.ptr, stem.ptr };
    job(&a1);
    var tb: [680]u8 = undefined;
    const txt = std.fmt.bufPrintSentinel(&tb, "{s}.txt", .{stem}, 0) catch return;
    const a2 = [_:null]?[*:0]const u8{ ptt.ptr, "-layout", "-f", num.ptr, "-l", num.ptr, src.ptr, txt.ptr };
    job(&a2);
}

/// A PDF's pages or an image, as pages to sort out.
fn addFile(path: []const u8) void {
    const k = extKind(path);
    if (k == 0) return;
    n_files += 1;
    if (k == 2) {
        const p = newPage(path, 0, 0) orelse return;
        const n = @min(path.len, p.png.len - 1);
        @memcpy(p.png[0..n], path[0..n]);
        p.png_len = @intCast(n);
        return;
    }
    if (!tools) {
        nopdf += 1;
        return;
    }
    var sb: [520]u8 = undefined;
    const src = std.fmt.bufPrintSentinel(&sb, "{s}", .{path}, 0) catch return;
    const pages = pdfPages(src);
    if (pages == 0) return;
    const t = if (stat(path)) |s| s.mtime else 0;
    var i: u32 = 1;
    while (i <= pages) : (i += 1) {
        const p = newPage(src, i, pages) orelse return;
        pageFiles(p, t);
        pump();
    }
}

/// The names in a folder that are PDFs or images, sorted, added.
fn scanFolder(in: []const u8) void {
    var zb: [600]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{in}, 0) catch return;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const S = struct {
        var names: [65536]u8 align(8) = undefined;
        var list: [MAXF][]const u8 = undefined;
        var dents: [16384]u8 align(8) = undefined;
    };
    var nl: usize = 0;
    var used: usize = 0;
    while (true) {
        const r = linux.getdents64(fd, &S.dents, S.dents.len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        var o: usize = 0;
        while (o < r) {
            const reclen = std.mem.readInt(u16, S.dents[o + 16..][0..2], .little);
            const typ = S.dents[o + 18];
            const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(S.dents[o + 19..].ptr)), 0);
            o += reclen;
            if (reclen == 0) break;
            if (typ == 4 or nm.len == 0 or nm[0] == '.' or extKind(nm) == 0) continue;
            if (nl >= MAXF or used + nm.len + 1 > S.names.len) continue;
            @memcpy(S.names[used..][0..nm.len], nm);
            S.list[nl] = S.names[used..][0..nm.len];
            used += nm.len + 1;
            nl += 1;
        }
    }
    const lt = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };
    std.sort.pdq([]const u8, S.list[0..nl], {}, lt.f);
    for (S.list[0..nl], 0..) |nm, i| {
        var pb: [800]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ in, nm }) catch continue;
        addFile(p);
        pf(i + 1, nl);
    }
}

// --- sorting them out ---------------------------------------------------------------

fn classifyAll() void {
    for (tab[0..n_pages], 0..) |*p, i| {
        const name = std.fs.path.basename(p.srcS());
        var text: ?[]const u8 = null;
        var raw: ?[]const u8 = null;
        if (p.page != 0) {
            var tb: [700]u8 = undefined;
            const t = std.fmt.bufPrint(&tb, "{s}.txt", .{stripExt(p.pngS())}) catch "";
            raw = @import("ttf.zig").mapFile(t);
            if (raw) |d| text = d[0..@min(d.len, 64 << 20)];
        }
        p.c = refclass.classify(name, text, p.npage);
        if (raw) |d| _ = linux.munmap(d.ptr, d.len);
        pf(i + 1, n_pages);
    }
    fillScales();
}

fn sameSrc(a: *const Page, b: ?*const Page) bool {
    return if (b) |q| std.mem.eql(u8, a.srcS(), q.srcS()) else true;
}

fn scaleCount(sc: u32, of: ?*const Page) u32 {
    var n: u32 = 0;
    for (tab[0..n_pages]) |*p| {
        if (p.c.scale == sc and !p.guess and sameSrc(p, of)) n += 1;
    }
    return n;
}

/// The scale most pages with one have (of that page's PDF; not guessed ones).
fn commonScale(of: ?*const Page) u32 {
    var best: u32 = 0;
    var cnt: u32 = 0;
    for (tab[0..n_pages]) |*p| {
        if (p.c.scale == 0 or p.guess or !sameSrc(p, of)) continue;
        const c = scaleCount(p.c.scale, of);
        if (c > cnt) {
            cnt = c;
            best = p.c.scale;
        }
    }
    return best;
}

/// A PDF page without a scale takes the one most of its PDF's pages have, else the set's.
fn fillScales() void {
    for (tab[0..n_pages]) |*p| {
        if (p.page == 0 or p.c.scale != 0) continue;
        var s = commonScale(p);
        if (s == 0) s = commonScale(null);
        if (s == 0) continue;
        p.c.scale = s;
        p.guess = true;
    }
}

// --- setting them up ---------------------------------------------------------------

const Group = enum(u8) { elev, plans, sect, site, terr, other, old };
const group_names = [_][]const u8{ "Elevations", "Plans", "Sections", "Site", "Terrain profiles", "Other drawings", "Existing" };
const group_shown = [_]bool{ true, true, false, false, false, false, false };

var fd_group: [7]u32 = @splat(0);
var fd_root: u32 = 0;
var show_all = false;
var last_root: u32 = 0;

fn groupOf(kind: Kind, old: bool) ?Group {
    if (kind == .legend) return null;
    if (old) return .old;
    return switch (kind) {
        .none, .front, .back, .left, .right, .elev => .elev,
        .plan => .plans,
        .section => .sect,
        .site => .site,
        .terrain => .terr,
        else => .other,
    };
}

/// A group's folder (made the first time: hidden unless shown).
fn groupFolder(g: Group) u32 {
    const i = @intFromEnum(g);
    if (fd_group[i] != 0) return fd_group[i];
    const uid = folders.make(group_names[i], fd_root);
    if (uid == 0) return 0;
    fd_group[i] = uid;
    if (!group_shown[i] and !show_all) folders.toggle(uid, folders.HIDDEN);
    return uid;
}

fn anyShown() bool {
    for (tab[0..n_pages]) |*p| {
        if (groupOf(p.c.kind, p.c.old)) |g| {
            if (group_shown[@intFromEnum(g)]) return true;
        }
    }
    return false;
}

/// The plan shown: the new ground floor (level 0), else the lowest new one at
/// 0 or above, else the first.
fn pickGround() ?usize {
    var best: ?usize = null;
    var bl: i32 = 1000;
    for (tab[0..n_pages], 0..) |*p, i| {
        if (groupOf(p.c.kind, p.c.old) != .plans) continue;
        const l = if (p.c.level < 0) p.c.level + 500 else p.c.level;
        if (l < bl) {
            bl = l;
            best = i;
        }
    }
    return best;
}

/// The level above the highest storey plan (the roof's).
fn topLevel() i32 {
    var t: i32 = 0;
    for (tab[0..n_pages]) |*p| {
        if (p.c.kind == .plan and p.c.level < refclass.LV_ROOF and p.c.level >= t) t = p.c.level + 1;
    }
    return if (t == 0) 1 else t;
}

/// Turned for its kind; standing on the ground, a plan at its level (its x and z kept).
fn orient(o: *scene.Object, kind: Kind, lv: i32, half_h: f32) void {
    o.rot = .{ 0, 0, 0 };
    switch (kind) {
        .plan => o.loc[1] = @as(f32, @floatFromInt(if (lv == refclass.LV_NONE) 0 else lv)) * 3,
        .site => o.loc[1] = -0.02,
        else => {
            o.rot[0] = 90;
            o.loc[1] = half_h;
            o.rot[1] = switch (kind) {
                .back => 180,
                .right => 90,
                .left => -90,
                else => 0,
            };
        },
    }
}

fn pngPixels(path: []const u8) ?u64 {
    var b: [1024]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{path}, 0) catch return null;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(rc));
    var h: [24]u8 = undefined;
    if (linux.read(@intCast(rc), &h, h.len) != h.len or !std.mem.eql(u8, h[1..4], "PNG")) return null;
    return @as(u64, std.mem.readInt(u32, h[16..20], .big)) * std.mem.readInt(u32, h[20..24], .big);
}

fn validUtf8Len(s: []const u8) usize {
    var n = s.len;
    while (n > 0 and !std.unicode.utf8ValidateSlice(s[0..n])) n -= 1;
    return n;
}

fn place(p: *Page, g: Group, roof: i32) bool {
    var nb: [40]u8 = undefined;
    const t0 = p.c.titleS();
    const t = t0[0..validUtf8Len(t0)];
    var name = std.fmt.bufPrint(&nb, "Ref {s}", .{t}) catch "Ref";
    name = name[0..validUtf8Len(name[0..@min(name.len, 25)])];
    if (p.c.old and name.len + 2 <= nb.len) {
        @memcpy(nb[name.len..][0..2], " B");
        name = nb[0 .. name.len + 2];
    }
    if (pngPixels(p.pngS())) |px| {
        if (pixels + px > MAX_PIXELS) {
            too_big += 1;
            return false;
        }
        pixels += px;
    }
    const a = refimg.addPath(p.pngS(), name) orelse return false;
    p.obj = a.index;
    const o = &scene.objects[a.index];
    o.ref &= ~refimg.BACK;
    // width (m): pixels x 0.254 mm x n, else 10 m
    var w: f32 = 10;
    if (p.c.scale != 0 and p.page != 0) w = @as(f32, @floatFromInt(p.c.scale)) * 0.000254 * @as(f32, @floatFromInt(refimg.last_w));
    const h = w / a.aspect;
    o.scl = .{ w * 0.5, 1, h * 0.5 };
    o.loc = .{ 0, 0, 0 };
    orient(o, p.c.kind, if (p.c.level == refclass.LV_ROOF) roof else p.c.level, h * 0.5);
    folders.setObject(o, groupFolder(g));
    return true;
}

fn placeAll() void {
    fd_group = @splat(0);
    var b: [140]u8 = undefined;
    fd_root = folders.make(std.fmt.bufPrint(&b, "Refs {s}", .{set_name}) catch "Refs", 0);
    last_root = fd_root;
    show_all = !anyShown();
    const ground = pickGround();
    const roof = topLevel();
    pixels = 0;
    too_big = 0;
    for (tab[0..n_pages], 0..) |*p, i| {
        defer pf(i + 1, n_pages);
        const g = groupOf(p.c.kind, p.c.old) orelse continue;
        if (!place(p, g, roof)) continue;
        if (g == .plans and (ground == null or ground.? != i)) {
            const o = &scene.objects[p.obj.?];
            o.visible = false;
            o.selected = false;
            continue;
        }
        p.shown = group_shown[@intFromEnum(g)] or show_all;
    }
}

fn countMade() u32 {
    var n: u32 = 0;
    for (tab[0..n_pages]) |*p| {
        if (p.obj != null) n += 1;
    }
    return n;
}

/// The console: what each page was taken for.
fn report() void {
    const root = folders.name(fd_root);
    app.log("  references: {d} pages from {d} files into the folder {s}", .{ countMade(), n_files, root });
    for (tab[0..n_pages]) |*p| {
        var b: [150]u8 = undefined;
        var w = std.Io.Writer.fixed(&b);
        const c = &p.c;
        w.print("    {s: <11}{s}", .{ refclass.kindName(c.kind), c.titleS() }) catch {};
        if (p.npage > 1) w.print(" p{d}", .{p.page}) catch {};
        if (c.kind == .legend) {
            w.writeAll(" (a legend: left out)") catch {};
        } else if (p.obj == null) {
            w.writeAll(" (could not be loaded)") catch {};
        } else {
            if (c.kind == .plan and c.level != refclass.LV_NONE) w.print(" level {d}", .{c.level}) catch {};
            if (c.scale != 0 and p.page != 0) {
                w.print(" 1:{d}", .{c.scale}) catch {};
                if (p.guess) w.writeAll(" (from other pages)") catch {};
            } else w.writeAll(" no scale: 10 m wide") catch {};
            if (c.old) w.writeAll(", existing") catch {};
            w.writeAll(if (p.shown) ", shown" else ", hidden") catch {};
        }
        app.log("{s}", .{w.buffered()});
    }
    toolsNote();
    if (too_big > 0) app.log("  references: {d} pages left out: more drawings than fit in memory", .{too_big});
    const n = countMade();
    if (n > 0) app.log("  references: {d} pages in {s} (Numpad 1 front, 3 right, 7 top)", .{ n, root });
}

fn run(path: []const u8, _: usize, _: usize) void {
    n_pages = 0;
    n_files = 0;
    n_jobs = 0;
    skipped = 0;
    nopdf = 0;
    var in = path;
    while (in.len > 1 and in[in.len - 1] == '/') in = in[0 .. in.len - 1];
    findTools();
    if (!makeDir(in)) {
        if (tools) app.log("  references: cannot make the folder for the pages: {s}", .{dir});
        tools = false;
    }
    const st = stat(in);
    if (st != null and st.?.mode & linux.S.IFMT == linux.S.IFDIR) {
        stage(0, 0.7);
        scanFolder(in);
    } else addFile(in);
    jobsEnd();
    if (n_pages == 0) {
        app.log("  references: no PDF or image there", .{});
        toolsNote();
        return;
    }
    stage(0.7, 0.1);
    classifyAll();
    stage(0.8, 0.2);
    placeAll();
    report();
    undo.label("Reference Images from Folder");
    app.dirty = true;
}

fn startJob(path: []const u8) void {
    jobui.later(run, "Importing reference drawings", path, 0, 0);
}

/// object.add_references <folder | file.pdf | image>
pub fn opAdd() void {
    const a = std.mem.trim(u8, ops.arg, " \"");
    if (a.len == 0) {
        @import("filebrowser.zig").show(.folder, "Reference Images from Folder", ".pdf .png .jpg .jpeg .hdr", "", startJob);
        return;
    }
    var pb: [1024]u8 = undefined;
    var p = files.expandHome(&pb, a) orelse return;
    // (a program must not take a name for an option)
    var rb: [1030]u8 = undefined;
    if (p[0] != '/') p = std.fmt.bufPrint(&rb, "./{s}", .{p}) catch return;
    startJob(p);
}

// --- pinning and re-sorting (the AI's tools; usable by hand) -----------------------------

/// How many numbers end a text (into nums, in order), and the text before them.
pub fn tailNums(t0: []const u8, nums: []f32) struct { n: usize, rest: []const u8 } {
    var t = std.mem.trimEnd(u8, t0, " ");
    var n: usize = 0;
    var taken: [8]f32 = undefined;
    while (n < nums.len) {
        const sp = std.mem.lastIndexOfScalar(u8, t, ' ') orelse break;
        const w = t[sp + 1 ..];
        const v = number(w) orelse break;
        taken[n] = v;
        n += 1;
        t = std.mem.trimEnd(u8, t[0..sp], " ");
    }
    for (0..n) |i| nums[i] = taken[n - 1 - i];
    return .{ .n = n, .rest = t };
}

fn number(w: []const u8) ?f32 {
    var digits: usize = 0;
    for (w, 0..) |c, i| {
        if (i == 0 and (c == '-' or c == '+')) continue;
        if (c == '.') continue;
        if (c < '0' or c > '9') return null;
        digits += 1;
    }
    if (digits == 0) return null;
    const v = std.fmt.parseFloat(f32, std.mem.trimStart(u8, w, "+")) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

fn refNamed(nm: []const u8) ?usize {
    const i = scene.find(nm) orelse return null;
    if (scene.objects[i].ref & refimg.REFIMG == 0) return null;
    if (refimg.imageOf(&scene.objects[i]) == null) return null;
    return i;
}

/// object.reference_pin <reference> <u> <v> <x> <y> <z>: the image's pixel u,v
/// moved to the point x,y,z.
pub fn opPin() void {
    const usage = "  object.reference_pin <reference> <u> <v> <x> <y> <z>: its image's pixel u,v moved to the point x,y,z";
    var nums: [5]f32 = undefined;
    const r = tailNums(std.mem.trim(u8, ops.arg, " \""), &nums);
    if (r.n != 5) return app.log(usage, .{});
    const i = refNamed(r.rest) orelse return app.log("  not a reference image: {s}", .{r.rest});
    const of = refimg.imageOf(&scene.objects[i]).?;
    const img = &images.list[of.ii].img;
    const x = nums[0] / @as(f32, @floatFromInt(img.w)) * 2 - 1; // (the image's top: -z)
    const z = nums[1] / @as(f32, @floatFromInt(img.h)) * 2 - 1;
    const p = m.xform(scene.world(i), .{ x, 0, z });
    const o = &scene.objects[i];
    for (0..3) |c| o.loc[c] += nums[2 + c] - p[c];
    undo.label("Pin Reference Pixel");
    app.dirty = true;
    app.log("  reference_pin: {s}: that pixel is at {d:.3} {d:.3} {d:.3}", .{ o.name(), nums[2], nums[3], nums[4] });
}

const kind_set = [_]struct { []const u8, Kind }{ .{ "front", .front }, .{ "back", .back }, .{ "left", .left }, .{ "right", .right }, .{ "plan", .plan }, .{ "section", .section }, .{ "site", .site }, .{ "terrain", .terrain }, .{ "other", .other } };

/// Into its kind's folder of the same set (existing ones stay in Existing),
/// hidden or shown as that folder is.
fn refile(o: *scene.Object, kind: Kind) void {
    const rec = folders.get(o.folder) orelse return;
    const set = rec.parent;
    if (folders.sameBase(folders.nameOf(rec), "Existing")) return;
    const g = groupOf(kind, false) orelse return;
    const gi = @intFromEnum(g);
    var uid = folders.child(group_names[gi], set);
    if (uid == 0) {
        fd_group[gi] = 0;
        fd_root = set;
        show_all = false;
        uid = groupFolder(g);
    }
    o.visible = true;
    folders.setObject(o, uid);
}

/// object.reference_kind <reference> front|back|left|right|plan|section|site|terrain|other [level [turn]]
pub fn opKind() void {
    const usage = "  object.reference_kind <reference> front|back|left|right|plan|section|site|terrain|other [level [turn]]";
    var nums: [2]f32 = undefined;
    const r = tailNums(std.mem.trim(u8, ops.arg, " \""), &nums);
    const sp = std.mem.lastIndexOfScalar(u8, r.rest, ' ') orelse return app.log(usage, .{});
    const kw = r.rest[sp + 1 ..];
    var kind: ?Kind = null;
    for (kind_set) |k| {
        if (std.ascii.eqlIgnoreCase(kw, k[0])) kind = k[1];
    }
    const nm = std.mem.trimEnd(u8, r.rest[0..sp], " ");
    const k = kind orelse return app.log(usage, .{});
    const i = refNamed(nm) orelse return app.log("  not a reference image: {s}", .{nm});
    const o = &scene.objects[i];
    const lv: i32 = if (r.n > 0 and @abs(nums[0]) < 1000) @intFromFloat(nums[0]) else 0;
    // (stood: on the ground, its scale z the half height)
    orient(o, k, lv, o.scl[2]);
    if (r.n >= 2 and (k == .plan or k == .site)) o.rot[1] = nums[1];
    refile(o, k);
    undo.label("Reference Kind");
    app.dirty = true;
    var b: [150]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    w.print("  reference_kind: {s} is now {s}", .{ o.name(), refclass.kindName(k) }) catch {};
    if (k == .plan) w.print(" level {d}", .{lv}) catch {};
    const fnm = folders.name(o.folder);
    if (fnm.len > 0) w.print(", in {s}", .{fnm}) catch {};
    app.log("{s}", .{w.buffered()});
}

// --- with the AI: reference_view, object.references_ai -----------------------------------

const mcp = @import("mcp.zig");
const cad = @import("cad.zig");

const rview_json = ",{\"name\":\"reference_view\",\"description\":\"Look at a reference image (a drawing or photo to model over, object.add_references): its picture as a PNG, at most 1024 px (thin lines kept), and what it is: its size in pixels, the metres a pixel is, how it stands and its folder. x0 y0 x1 y1 (its pixels; 0,0 its top-left) show a part of it closer, to read a pixel exactly for object.reference_pin.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"the reference's object\"},\"x0\":{\"type\":\"number\"},\"y0\":{\"type\":\"number\"},\"x1\":{\"type\":\"number\"},\"y1\":{\"type\":\"number\"}},\"required\":[\"name\"]}}";

/// rs_tier: reference_view only looks.
fn rvTier(tool: []const u8) ?u32 {
    return if (std.mem.eql(u8, tool, "reference_view")) 0 else null;
}

fn rvDispatch(tool: []const u8) bool {
    if (!std.mem.eql(u8, tool, "reference_view")) return false;
    view();
    return true;
}

/// The MCP server's refs slot (rs_tools_json, rs_tier, rs_dispatch).
pub const mcp_provider = mcp.Provider{ .tools_json = rview_json, .tier = rvTier, .dispatch = rvDispatch };

/// rs_arg_px: a pixel argument (a number, cut toward zero; below 0: 0; past
/// `most`: most), else the default.
fn argPx(key: []const u8, def: i32, most: i32) i32 {
    const v = mcp.argVal(key) orelse return def;
    const nv = json.num(mcp.msg, v);
    if (!nv.ok) return def;
    // (cvttss2si: out of range or NaN gives the "integer indefinite", negative)
    const x: i32 = if (nv.v > -2147483648.0 and nv.v < 2147483648.0) @intFromFloat(nv.v) else std.math.minInt(i32);
    if (x < 0) return 0;
    return @min(x, most);
}
const json = @import("json.zig");

/// rs_stands: how it stands, for the AI.
fn stands(o: *const scene.Object) []const u8 {
    if (!(@abs(o.rot[0]) >= 0.1)) return "lies flat (a plan: the image's top towards -Z, its left towards -X)";
    const ry = o.rot[1];
    if (!(@abs(ry) >= 0.1)) return "stands facing +Z (the front: the image's left towards -X)";
    if (@abs(ry) > 2.6) return "stands facing -Z (the rear: the image's left towards +X)";
    if (ry > 0) return "stands facing +X (the right side: the image's left towards +Z)";
    return "stands facing -X (the left side: the image's left towards -Z)";
}

/// reference_view {name, x0, y0, x1, y1}: the picture (each pixel the darkest
/// of its block, per channel), what it is (the text).
fn view() void {
    var nb: [60]u8 = undefined;
    const nm = mcp.argStr("name", &nb) orelse "";
    if (nm.len == 0) return mcp.fail("name: a reference image's object", "");
    const oi = refNamed(nm) orelse return mcp.fail("no reference image named ", nm);
    const o = &scene.objects[oi];
    const e = &images.list[refimg.imageOf(o).?.ii];
    if (e.img.hdr) return mcp.fail("an HDR image: not shown", "");
    const W: i32 = @intCast(e.img.w);
    const H: i32 = @intCast(e.img.h);
    const x0 = argPx("x0", 0, W - 1);
    const y0 = argPx("y0", 0, H - 1);
    var x1 = argPx("x1", W, W);
    var y1 = argPx("y1", H, H);
    if (x1 <= x0) x1 = x0 + 1; // (at least a pixel)
    if (y1 <= y0) y1 = y0 + 1;
    const sw: u32 = @intCast(x1 - x0);
    const sh: u32 = @intCast(y1 - y0);
    const k: u32 = @max(1, (@max(sw, sh) + 1023) / 1024); // 1024 px at most
    const ow = (sw + k - 1) / k;
    const oh = (sh + k - 1) / k;
    const A = std.heap.page_allocator;
    const px = A.alloc(u32, @as(usize, ow) * oh) catch return mcp.fail("no room for the picture", "");
    defer A.free(px);
    if (e.b8.len != @as(usize, e.img.w) * e.img.h) return mcp.fail("no room for the picture", "");
    for (0..oh) |oy| {
        const ry0 = @as(u32, @intCast(y0)) + @as(u32, @intCast(oy)) * k;
        const ry1 = @min(ry0 + k, @as(u32, @intCast(y1)));
        for (0..ow) |ox| {
            const rx0 = @as(u32, @intCast(x0)) + @as(u32, @intCast(ox)) * k;
            const rx1 = @min(rx0 + k, @as(u32, @intCast(x1)));
            var mn = [3]u8{ 255, 255, 255 };
            var yy = ry0;
            while (yy < ry1) : (yy += 1) {
                var xx = rx0;
                while (xx < rx1) : (xx += 1) {
                    const p = e.b8[@as(usize, yy) * e.img.w + xx];
                    for (0..3) |c| mn[c] = @min(mn[c], p[c]);
                }
            }
            px[oy * ow + ox] = @as(u32, mn[0]) << 16 | @as(u32, mn[1]) << 8 | mn[2];
        }
    }
    const png = @import("png.zig").encode(A, ow, oh, px) catch return mcp.fail("no room for the picture", "");
    mcp.setImage(png);
    const t = &mcp.txt;
    var b: [256]u8 = undefined;
    t.raw(nm);
    t.raw(std.fmt.bufPrint(&b, ": {d} x {d} px; 1 px = ", .{ W, H }) catch "");
    t.float(o.scl[0] * 2 / @as(f32, @floatFromInt(W)));
    t.raw(std.fmt.bufPrint(&b, " m (at its size now); shown: x {d}..{d}, y {d}..{d} at 1/{d} (darkest pixel kept). Pixel 0,0 is its top-left. It ", .{ x0, x1, y0, y1, k }) catch "");
    t.raw(stands(o));
    if (folders.get(o.folder)) |f| {
        t.raw("; in ");
        t.raw(folders.nameOf(f));
    }
    if (!o.visible) t.raw("; hidden");
}

/// rs_pick_set: the folder of the set to line up: the active reference's set
/// (its folder's parent, or that folder), else the last import's (0: none).
fn pickSet() u32 {
    if (scene.active) |a| {
        const o = &scene.objects[a];
        if (o.ref & refimg.REFIMG != 0 and o.folder != 0) {
            if (folders.get(o.folder)) |f| return if (f.parent != 0) f.parent else o.folder;
        }
    }
    if (last_root != 0 and folders.index(last_root) != null) return last_root;
    return 0;
}

const ai_head = "\n\n--- The reference drawings (BeeModel's AI > Line Up References) ---\n";
const ai_rules = "These reference images were made from a building's drawings (object.add_references): each PDF page sorted out by its name and title block, at the scale written on it, in the outliner folder named below. Check them and line them up so they agree, then say in a few lines what you changed.\n" ++
    "1. Look at each one with reference_view (x0 y0 x1 y1 zoom into a part, in the image's pixels; do zoom in before reading a pixel exactly).\n" ++
    "2. One taken for the wrong kind: run_operator object.reference_kind with arg \"<name> front|back|left|right|plan|section|site|terrain|other [level [turn]]\" (level: a plan's storey, 0 the ground floor; turn: degrees about Y, for a plan whose front is not at the bottom of its image).\n" ++
    "3. Line them up with run_operator object.reference_pin, arg \"<name> <u> <v> <x> <y> <z>\": the image's pixel u,v goes to the point x,y,z (metres, Y up). The origin is the building's front-left corner at ground level (floor 0); the front faces +Z, the building runs to +X (its width W) and to -Z (its depth D); read W and D off the ground floor plan (its pixels times the metres a pixel that reference_view gives).\n" ++
    "   front elevation: the left end of its ground line -> 0 0 0. rear: the left end of its ground line -> W 0 -D. right side: -> W 0 0. left side: -> 0 0 -D. Plans: the front-left corner of the outline -> 0 h 0, h the storey's floor height (read the levels, e.g. +3.00, off a section or an elevation; 3 m a storey when none is given). Sections: the end of the ground line on the side the plan's cut line starts.\n" ++
    "4. Leave the hidden ones (existing state, other pages) hidden unless they are needed; do not change a reference's size.\n" ++
    "The references (name: folder, how it stands, size, image pixels):\n";

const PROMPT = 32768;
var prompt: [PROMPT]u8 = undefined;
var plen: usize = 0;

/// rs_add: onto the prompt (it stops 8 bytes short of its end).
fn add(s: []const u8) void {
    for (s) |c| {
        if (plen >= PROMPT - 8 or c == 0) return;
        prompt[plen] = c;
        plen += 1;
    }
}

/// rs_line_of: "how it stands; in <folder>[; hidden], W x H m, w x h px\n".
fn lineOf(o: *const scene.Object) void {
    add(stands(o));
    add("; in ");
    if (folders.get(o.folder)) |f| add(folders.nameOf(f));
    if (!o.visible) add("; hidden");
    add(", ");
    var vb: [32]u8 = undefined;
    add(cad.fmtVal3(&vb, o.scl[0] * 2));
    add(" x ");
    add(cad.fmtVal3(&vb, o.scl[2] * 2));
    add(" m, ");
    if (refimg.imageOf(o)) |of| {
        const im = &images.list[of.ii].img;
        add(std.fmt.bufPrint(&vb, "{d} x {d} px", .{ im.w, im.h }) catch "");
    }
    add("\n");
}

/// The prompt for a set (its folder); how many references are in it.
pub fn aiPrompt(set: u32) struct { text: []const u8, n: u32 } {
    plen = 0;
    add(ai_head);
    add(ai_rules);
    add("Folder: ");
    add(folders.name(set));
    add("\n");
    var n: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.ref & refimg.REFIMG == 0 or !folders.inside(o.folder, set)) continue;
        n += 1;
        if (plen >= PROMPT - 600) continue;
        add("- ");
        add(o.name());
        add(": ");
        lineOf(o);
    }
    return .{ .text = prompt[0..plen], .n = n };
}

/// object.references_ai: the AI Assistant asked to check and line up the
/// references of a set (the selected reference's, else the last import's).
pub fn opAi() void {
    const none = "  no reference drawings to line up (Add > Reference Images from Folder...)";
    const set = pickSet();
    if (set == 0) return app.log(none, .{});
    const p = aiPrompt(set);
    if (p.n == 0) return app.log(none, .{});
    var sb: [501]u8 = undefined;
    const shown = std.fmt.bufPrint(&sb, "Line up the reference drawings in {s}", .{folders.name(set)}) catch sb[0..500];
    if (@import("aihook.zig").show) |f| f(); // the AI Assistant in view
    _ = @import("aihook.zig").send(shown, p.text, null);
    app.dirty = true;
}

test "numbers at the end" {
    var n: [5]f32 = undefined;
    const r = tailNums("Ref Voorgevel 10 20 1.5 -2 +3", &n);
    try std.testing.expectEqual(@as(usize, 5), r.n);
    try std.testing.expectEqualStrings("Ref Voorgevel", r.rest);
    try std.testing.expectEqual(@as(f32, 10), n[0]);
    try std.testing.expectEqual(@as(f32, -2), n[3]);
    try std.testing.expectEqual(@as(f32, 3), n[4]);
    var k: [2]f32 = undefined;
    const q = tailNums("a b plan 2", &k);
    try std.testing.expectEqual(@as(usize, 1), q.n);
    try std.testing.expectEqualStrings("a b plan", q.rest);
    try std.testing.expectEqual(@as(usize, 0), tailNums("alone", &k).n);
    try std.testing.expectEqual(@as(?f32, null), number("."));
    try std.testing.expectEqual(@as(?f32, null), number("1x"));
}

test "the number of pages" {
    try std.testing.expectEqual(@as(u32, 12), pagesIn("Title: x\nPages:          12\nEncrypted: no\n"));
    try std.testing.expectEqual(@as(u32, 0), pagesIn("no such line"));
    try std.testing.expectEqual(@as(u32, 10_000_000), pagesIn("Pages: 99999999999999999999999"));
}
