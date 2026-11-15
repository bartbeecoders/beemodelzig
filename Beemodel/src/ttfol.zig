//! The original's TrueType loading and outline walk (ttf.s: font_load_at,
//! glyph_index, glyph_data, outline_glyph, outline_simple, decode_coords,
//! emit_contour, quad_to) with its hooks: a contour starts (ol_begin), an
//! edge ends at a point (ol_line), a simple glyph or a composite's part is done
//! (ol_end). 3D text (text3d.zig) collects its loops through them.
//!
//! The UI's text does not come through here: it keeps ttf.zig's own walk and
//! rasterizer, so what the interface draws is as it was. This walk is the
//! original's, in its order of operations, f32 lane for lane (the flattening:
//! sqrt(1.5 (|dx| + |dy|)) + 1 pieces, 16 at most; points through the
//! transform, times r_scale, y flipped about r_oy), so text meshes come out bit
//! for bit as the original's. Where the original reads past a table or the
//! file (a damaged font), this stops instead.
const std = @import("std");
const linux = std.os.linux;

pub const MAXPTS = 4096;

/// A loaded font (the original's FNT_* fields that the walk uses).
pub const Font = struct {
    data: []const u8 = &.{},
    glyf: usize = 0,
    loca: usize = 0,
    hmtx: usize = 0,
    cmap: usize = 0, // the chosen subtable
    cmap_fmt: u32 = 0,
    upem: u32 = 0,
    locfmt: i32 = 0,
    nhm: u32 = 0,
    nglyph: u32 = 0,
    loaded: bool = false,

    fn u8At(f: *const Font, o: usize) u8 {
        return if (o < f.data.len) f.data[o] else 0;
    }
    pub fn u16At(f: *const Font, o: usize) u32 {
        if (o +% 2 > f.data.len or o > f.data.len) return 0;
        return std.mem.readInt(u16, f.data[o..][0..2], .big);
    }
    fn i16At(f: *const Font, o: usize) i32 {
        return @as(i16, @bitCast(@as(u16, @intCast(f.u16At(o)))));
    }
    fn u32At(f: *const Font, o: usize) u32 {
        if (o +% 4 > f.data.len or o > f.data.len) return 0;
        return std.mem.readInt(u32, f.data[o..][0..4], .big);
    }

    /// font_load_at's table work on a mapped file: true when it is usable
    /// (head, hhea, maxp, cmap, glyf, loca, hmtx; a Unicode cmap 4 or 12).
    pub fn parse(f: *Font, data: []const u8) bool {
        f.* = .{ .data = data };
        if (data.len < 12) return false;
        const n = f.u16At(4);
        var head: usize = 0;
        var hhea: usize = 0;
        var maxp: usize = 0;
        var cmapt: usize = 0;
        var i: u32 = 0;
        var rec: usize = 12;
        while (i < n) : (i += 1) {
            defer rec += 16;
            if (rec + 16 > data.len) break;
            const off: usize = f.u32At(rec + 8);
            if (off >= data.len) continue;
            const tag = data[rec..][0..4];
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "cmap")) cmapt = off;
            if (std.mem.eql(u8, tag, "hmtx")) f.hmtx = off;
            if (std.mem.eql(u8, tag, "loca")) f.loca = off;
            if (std.mem.eql(u8, tag, "glyf")) f.glyf = off;
        }
        // (an offset of 0 is the file's start: the original's "none" too)
        if (head == 0 or hhea == 0 or maxp == 0 or cmapt == 0) return false;
        if (f.glyf == 0 or f.loca == 0 or f.hmtx == 0) return false;
        f.upem = f.u16At(head + 18);
        if (f.upem == 0) return false;
        f.locfmt = f.i16At(head + 50);
        f.nhm = f.u16At(hhea + 34);
        if (f.nhm == 0) return false;
        f.nglyph = f.u16At(maxp + 4);
        // the best cmap subtable: Unicode (platform 0) +1; format 4 +1, 12 +3
        const nsub = f.u16At(cmapt + 2);
        var best: u32 = 0;
        var k: u32 = 0;
        var r: usize = cmapt + 4;
        while (k < nsub) : (k += 1) {
            defer r += 8;
            const plat = f.u16At(r);
            const enc = f.u16At(r + 2);
            const sub = cmapt + f.u32At(r + 4);
            const fmt = f.u16At(sub);
            var score: u32 = 0;
            if (plat == 3) {
                if (enc != 1 and enc != 10) continue;
            } else if (plat == 0) {
                score = 1;
            } else continue;
            if (fmt == 4) {
                score += 1;
            } else if (fmt == 12) {
                score += 3;
            } else continue;
            if (score <= best) continue;
            best = score;
            f.cmap = sub;
            f.cmap_fmt = fmt;
        }
        if (best == 0) return false;
        f.loaded = true;
        return true;
    }

    /// glyph_index(code point): its glyph (0: missing).
    pub fn glyphIndex(f: *const Font, cp: u32) u32 {
        const c = f.cmap;
        if (f.cmap_fmt == 12) {
            var n = f.u32At(c + 12);
            var g: usize = c + 16;
            while (n != 0) : (n -= 1) {
                defer g += 12;
                if (g + 12 > f.data.len) return 0;
                const st = f.u32At(g);
                if (cp < st) continue;
                if (cp > f.u32At(g + 4)) continue;
                return f.u32At(g + 8) +% (cp - st);
            }
            return 0;
        }
        if (cp > 0xffff) return 0;
        const segx2: usize = f.u16At(c + 6);
        const ends = c + 14;
        var d: usize = 0;
        while (true) : (d += 2) {
            if (d >= segx2) return 0;
            if (ends + d + 2 > f.data.len) return 0;
            if (cp <= f.u16At(ends + d)) break;
        }
        const starts = ends + segx2 + 2;
        const start = f.u16At(starts + d);
        if (cp < start) return 0;
        const deltas = starts + segx2;
        const delta = f.u16At(deltas + d);
        const ranges = deltas + segx2;
        const ro = f.u16At(ranges + d);
        if (ro == 0) return (cp +% delta) & 0xffff;
        const g = f.u16At(ranges + d + ro + (cp - start) * 2);
        if (g == 0) return 0;
        return (g +% delta) & 0xffff;
    }

    /// glyph_data(glyph): its bytes (empty: none).
    pub fn glyphData(f: *const Font, g: u32) []const u8 {
        if (g >= f.nglyph) return &.{};
        var a: usize = undefined;
        var b: usize = undefined;
        if (f.locfmt == 0) {
            a = @as(usize, f.u16At(f.loca + @as(usize, g) * 2)) * 2;
            b = @as(usize, f.u16At(f.loca + @as(usize, g) * 2 + 2)) * 2;
        } else {
            a = f.u32At(f.loca + @as(usize, g) * 4);
            b = f.u32At(f.loca + @as(usize, g) * 4 + 4);
        }
        if (b <= a) return &.{};
        const s = f.glyf + a;
        if (s >= f.data.len) return &.{};
        return f.data[s..@min(f.data.len, f.glyf + b)];
    }

    /// hmtx: a glyph's advance width (font units) and units per em.
    pub fn advanceUnits(f: *const Font, g: u32) u32 {
        const i = @min(g, f.nhm - 1);
        return f.u16At(f.hmtx + @as(usize, i) * 4);
    }
};

/// font_load_at(path): the font mapped and parsed (false: not a usable font).
pub fn load(f: *Font, path: []const u8) bool {
    const d = mapFile(path) orelse {
        f.* = .{};
        return false;
    };
    if (f.parse(d)) return true;
    _ = linux.munmap(d.ptr, d.len);
    f.* = .{};
    return false;
}

/// The font's file unmapped.
pub fn unload(f: *Font) void {
    if (f.data.len > 0) _ = linux.munmap(f.data.ptr, f.data.len);
    f.* = .{};
}

fn mapFile(path: []const u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&buf);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const sz = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(sz) != .SUCCESS or sz < 12 or sz > 4 << 30) return null;
    const size: usize = sz;
    const mp = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(mp) != .SUCCESS) return null;
    const ptr: [*]const u8 = @ptrFromInt(mp);
    return ptr[0..size];
}

// ---- the walk ---------------------------------------------------------------------------

/// The hooks (text3d.zig): a contour starts at (x, y); an edge ends at (x, y);
/// a simple glyph (or a composite's part) is done.
pub const Hooks = struct {
    begin: *const fn (f32, f32) void,
    line: *const fn (f32, f32) void,
    end: *const fn () void,
};

pub var r_font: ?*const Font = null;
pub var r_scale: f32 = 0;
pub var r_ox: f32 = 0;
pub var r_oy: f32 = 0;
var hooks: Hooks = undefined;

pub const xf_ident = [6]f32{ 1, 0, 0, 1, 0, 0 };

var flagbuf: [MAXPTS]u8 = undefined;
var ixs: [MAXPTS]i32 = undefined;
var iys: [MAXPTS]i32 = undefined;
var ptx: [MAXPTS]f32 = undefined;
var pty: [MAXPTS]f32 = undefined;
var c_sx: f32 = 0;
var c_sy: f32 = 0;
var c_px: f32 = 0;
var c_py: f32 = 0;
var c_cx: f32 = 0;
var c_cy: f32 = 0;

/// outline_glyph with the hooks: r_font's glyph g through the transform.
pub fn walk(g: u32, h: Hooks) void {
    hooks = h;
    outlineGlyph(g, &xf_ident, 0);
}

fn outlineGlyph(g: u32, t: *const [6]f32, depth: u32) void {
    if (depth > 6) return;
    const f = r_font orelse return;
    const d = f.glyphData(g);
    if (d.len == 0) return;
    const base = @intFromPtr(d.ptr) - @intFromPtr(f.data.ptr);
    const nc = f.i16At(base);
    if (nc == 0) return;
    if (nc > 0) return outlineSimple(f, base, t);
    var o = base + 10;
    while (true) {
        if (o + 4 > f.data.len) return;
        const fl = f.u16At(o);
        const cg = f.u16At(o + 2);
        o += 4;
        var e: i32 = undefined;
        var ff: i32 = undefined;
        if (fl & 1 != 0) {
            e = f.i16At(o);
            ff = f.i16At(o + 2);
            o += 4;
        } else {
            e = @as(i8, @bitCast(f.u8At(o)));
            ff = @as(i8, @bitCast(f.u8At(o + 1)));
            o += 2;
        }
        if (fl & 2 == 0) {
            e = 0;
            ff = 0;
        }
        const xe: f32 = @floatFromInt(e);
        const xf: f32 = @floatFromInt(ff);
        var a: f32 = 1;
        var b: f32 = 0;
        var c: f32 = 0;
        var dd: f32 = 1;
        if (fl & 0x08 != 0) {
            a = @as(f32, @floatFromInt(f.i16At(o))) / 16384.0;
            dd = a;
            o += 2;
        } else if (fl & 0x40 != 0) {
            a = @as(f32, @floatFromInt(f.i16At(o))) / 16384.0;
            dd = @as(f32, @floatFromInt(f.i16At(o + 2))) / 16384.0;
            o += 4;
        } else if (fl & 0x80 != 0) {
            a = @as(f32, @floatFromInt(f.i16At(o))) / 16384.0;
            b = @as(f32, @floatFromInt(f.i16At(o + 2))) / 16384.0;
            c = @as(f32, @floatFromInt(f.i16At(o + 4))) / 16384.0;
            dd = @as(f32, @floatFromInt(f.i16At(o + 6))) / 16384.0;
            o += 8;
        }
        // child = parent o component
        const ch = [6]f32{
            t[0] * a + t[2] * b,
            t[1] * a + t[3] * b,
            t[0] * c + t[2] * dd,
            t[1] * c + t[3] * dd,
            (t[0] * xe + t[2] * xf) + t[4],
            (t[1] * xe + t[3] * xf) + t[5],
        };
        outlineGlyph(cg, &ch, depth + 1);
        if (fl & 0x20 == 0) return;
    }
}

fn outlineSimple(f: *const Font, base: usize, t: *const [6]f32) void {
    defer hooks.end();
    const nc: u32 = f.u16At(base);
    const eo = base + 10; // endPtsOfContours[]
    const npts = f.u16At(eo + nc * 2 - 2) + 1;
    if (npts > MAXPTS) return;
    const ilen = f.u16At(eo + nc * 2);
    var s = eo + nc * 2 + 2 + ilen;
    // flags, with repeats
    var i: u32 = 0;
    while (i < npts) {
        if (s >= f.data.len) return;
        const fl = f.data[s];
        s += 1;
        flagbuf[i] = fl;
        i += 1;
        if (fl & 8 == 0) continue;
        var rep: u32 = f.u8At(s);
        s += 1;
        while (rep != 0 and i < npts) : (rep -= 1) {
            flagbuf[i] = fl;
            i += 1;
        }
    }
    if (!decode(f, &s, &ixs, 0x02, 0x10, npts)) return;
    if (!decode(f, &s, &iys, 0x04, 0x20, npts)) return;
    for (0..npts) |k| {
        const x: f32 = @floatFromInt(ixs[k]);
        const y: f32 = @floatFromInt(iys[k]);
        var px = t[0] * x;
        px += t[2] * y;
        px += t[4];
        px *= r_scale;
        px += r_ox;
        ptx[k] = px;
        var py = t[1] * x;
        py += t[3] * y;
        py += t[5];
        py *= r_scale;
        pty[k] = r_oy - py;
    }
    var start: u32 = 0;
    var c: u32 = 0;
    while (c < nc) : (c += 1) {
        const last = f.u16At(eo + c * 2);
        if (last >= npts) return;
        // (a contour ending before it starts: the original reads on past its
        // points; here it is left out)
        if (last >= start) emitContour(start, last);
        start = last + 1;
    }
}

fn decode(f: *const Font, s: *usize, out: *[MAXPTS]i32, short: u8, same: u8, n: u32) bool {
    var v: i32 = 0;
    for (0..n) |k| {
        const fl = flagbuf[k];
        if (fl & short != 0) {
            if (s.* >= f.data.len) return false;
            const d: i32 = f.data[s.*];
            s.* += 1;
            v +%= if (fl & same != 0) d else -d;
        } else if (fl & same == 0) {
            if (s.* + 2 > f.data.len) return false;
            v +%= f.i16At(s.*);
            s.* += 2;
        }
        out[k] = v;
    }
    return true;
}

fn emitContour(first: u32, last: u32) void {
    const cnt = last - first + 1;
    if (cnt < 2) return;
    var at: u32 = undefined;
    var left: u32 = undefined;
    var sx: f32 = undefined;
    var sy: f32 = undefined;
    if (flagbuf[first] & 1 != 0) {
        sx = ptx[first];
        sy = pty[first];
        at = first + 1;
        left = cnt - 1;
    } else if (flagbuf[last] & 1 != 0) {
        sx = ptx[last];
        sy = pty[last];
        at = first;
        left = cnt - 1;
    } else {
        sx = (ptx[first] + ptx[last]) * 0.5;
        sy = (pty[first] + pty[last]) * 0.5;
        at = first;
        left = cnt;
    }
    c_sx = sx;
    c_sy = sy;
    c_px = sx;
    c_py = sy;
    hooks.begin(sx, sy);
    var pend = false;
    while (left != 0) : ({
        at += 1;
        left -= 1;
    }) {
        const qx = ptx[at];
        const qy = pty[at];
        if (flagbuf[at] & 1 != 0) {
            if (pend) quadTo(qx, qy) else hooks.line(qx, qy);
            c_px = qx;
            c_py = qy;
            pend = false;
        } else {
            if (pend) {
                const mx = (qx + c_cx) * 0.5;
                const my = (qy + c_cy) * 0.5;
                quadTo(mx, my);
                c_px = mx;
                c_py = my;
            }
            c_cx = qx;
            c_cy = qy;
            pend = true;
        }
    }
    if (pend) quadTo(c_sx, c_sy) else hooks.line(c_sx, c_sy);
}

/// quad_to(end): from (c_px, c_py) by (c_cx, c_cy), in sqrt(1.5 (|ddx| +
/// |ddy|)) + 1 pieces (16 at most).
fn quadTo(ex: f32, ey: f32) void {
    var ax = c_px - (c_cx + c_cx);
    ax += ex;
    var ay = c_py - (c_cy + c_cy);
    ay += ey;
    var s = @abs(ax) + @abs(ay);
    s *= 1.5;
    s = @sqrt(s);
    // cvttss2si (in range: s is at most sqrt of a finite float's sum)
    var n: u32 = if (s < 2147483647.0) @as(u32, @intFromFloat(@trunc(s))) + 1 else 0x80000001;
    if (n > 16) n = 16;
    const fn_: f32 = @floatFromInt(n);
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        var tt: f32 = @floatFromInt(i);
        tt /= fn_;
        const mt = 1.0 - tt;
        const mt2 = mt * mt;
        var tm = tt * mt;
        tm += tm;
        const t2 = tt * tt;
        var x = c_px * mt2;
        x += c_cx * tm;
        x += ex * t2;
        var y = c_py * mt2;
        y += c_cy * tm;
        y += ey * t2;
        hooks.line(x, y);
    }
}
