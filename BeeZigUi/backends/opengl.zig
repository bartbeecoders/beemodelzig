//! OpenGL 3.3 renderer for `zui.Renderer`.
//!
//! Draws everything with one shader and a batched vertex buffer: rounded
//! rects with borders, shadows and text from a glyph atlas. It uses the same
//! distance and coverage math as the software rasterizer, and the same glyph
//! bitmaps and pen positions, so both renderers produce the same picture.
//!
//! It knows nothing about windows: pass a function that looks up GL entry
//! points (SDL's `SDL_GL_GetProcAddress`, GLFW's `glfwGetProcAddress`, ...),
//! with a GL 3.3 core context current.

const std = @import("std");
const zui = @import("zui");
const Allocator = std.mem.Allocator;
const Color = zui.Color;
const Rect = zui.Rect;

/// Looks up a GL function by name.
pub const Loader = *const fn (name: [*:0]const u8) ?*const anyopaque;

/// Why the renderer could not start.
pub const Error = error{ MissingGlFunction, ShaderFailed } || Allocator.Error;

/// A renderer that draws into the current GL framebuffer.
pub const GlRenderer = struct {
    allocator: Allocator,
    gl: Gl,
    program: u32 = 0,
    vao: u32 = 0,
    vbo: u32 = 0,
    atlas: u32 = 0,
    viewport_uniform: i32 = -1,
    vertices: std.ArrayList(Vertex) = .empty,
    tess: zui.tessellate.Tessellator,
    /// Uploaded images by `Image.id`.
    textures: std.AutoHashMapUnmanaged(u32, Texture) = .empty,
    /// The image texture the queued vertices sample, and how.
    bound_image: u32 = 0,
    bound_filter: zui.Filter = .nearest,
    /// Scratch for converting images to premultiplied alpha.
    upload: std.ArrayList(u32) = .empty,
    frame_number: u64 = 0,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, AtlasSlot) = .empty,
    shelf: Shelf = .{},
    /// Cleared to this at the start of each frame.
    clear_color: Color = Color.hex(0x202226),
    scale: f32 = 1,
    /// Framebuffer size in pixels.
    width: u32 = 0,
    height: u32 = 0,

    const atlas_size = 1024;

    /// Compiles the shader and creates the buffers. Needs a current GL 3.3
    /// core context. Pair with `deinit`, in the same context.
    pub fn init(allocator: Allocator, loader: Loader) Error!GlRenderer {
        var self: GlRenderer = .{ .allocator = allocator, .gl = try .load(loader), .tess = .init(allocator) };
        const gl = &self.gl;
        self.program = try buildProgram(gl);
        self.viewport_uniform = gl.GetUniformLocation(self.program, "viewport");
        gl.UseProgram(self.program);
        gl.Uniform1i(gl.GetUniformLocation(self.program, "atlas"), 0);
        gl.Uniform1i(gl.GetUniformLocation(self.program, "image"), 1);

        gl.GenVertexArrays(1, &self.vao);
        gl.BindVertexArray(self.vao);
        gl.GenBuffers(1, &self.vbo);
        gl.BindBuffer(GL_ARRAY_BUFFER, self.vbo);
        const stride: i32 = @sizeOf(Vertex);
        const attribs = [_]struct { u32, i32, u32, u8, usize }{
            .{ 0, 2, GL_FLOAT, GL_FALSE, @offsetOf(Vertex, "pos") },
            .{ 1, 2, GL_FLOAT, GL_FALSE, @offsetOf(Vertex, "local") },
            .{ 2, 2, GL_FLOAT, GL_FALSE, @offsetOf(Vertex, "half") },
            .{ 3, 4, GL_FLOAT, GL_FALSE, @offsetOf(Vertex, "params") },
            .{ 4, 4, GL_UNSIGNED_BYTE, GL_TRUE, @offsetOf(Vertex, "fill") },
            .{ 5, 4, GL_UNSIGNED_BYTE, GL_TRUE, @offsetOf(Vertex, "border") },
        };
        for (attribs) |a| {
            const index, const size, const kind, const normalized, const offset = a;
            gl.EnableVertexAttribArray(index);
            gl.VertexAttribPointer(index, size, kind, normalized, stride, @ptrFromInt(offset));
        }

        gl.GenTextures(1, &self.atlas);
        gl.BindTexture(GL_TEXTURE_2D, self.atlas);
        gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlas_size, atlas_size, 0, GL_RED, GL_UNSIGNED_BYTE, null);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        return self;
    }

    /// Frees GL objects and memory.
    pub fn deinit(self: *GlRenderer) void {
        const gl = &self.gl;
        gl.DeleteTextures(1, &self.atlas);
        gl.DeleteBuffers(1, &self.vbo);
        gl.DeleteVertexArrays(1, &self.vao);
        gl.DeleteProgram(self.program);
        var it = self.textures.valueIterator();
        while (it.next()) |t| gl.DeleteTextures(1, &t.name);
        self.textures.deinit(self.allocator);
        self.upload.deinit(self.allocator);
        self.tess.deinit();
        self.vertices.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
    }

    /// Drops the GPU copy of an image you no longer draw. Optional: copies
    /// unused for a few seconds are dropped anyway.
    pub fn forgetImage(self: *GlRenderer, id: u32) void {
        if (self.textures.fetchRemove(id)) |kv| {
            if (self.bound_image == id) {
                self.flush();
                self.bound_image = 0;
            }
            self.gl.DeleteTextures(1, &kv.value.name);
        }
    }

    /// Returns the type-erased interface.
    pub fn renderer(self: *GlRenderer) zui.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The pixel at (`x`, `y`) in physical pixels from the top left, or
    /// null outside the framebuffer. For the eyedropper; call it before
    /// swapping buffers.
    pub fn pixelAt(self: *GlRenderer, x: i32, y: i32) ?Color {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        const gl = &self.gl;
        var rgba: [4]u8 = undefined;
        gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
        gl.ReadPixels(x, @as(i32, @intCast(self.height)) - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &rgba);
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = 255 };
    }

    /// Copies the framebuffer into `out` as `0xAARRGGBB`, row 0 at the top,
    /// the layout the software renderer uses. For tests and screenshots.
    pub fn readPixels(self: *GlRenderer, out: []u32) void {
        std.debug.assert(out.len >= @as(usize, self.width) * self.height);
        const gl = &self.gl;
        gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
        gl.ReadPixels(0, 0, @intCast(self.width), @intCast(self.height), GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
        // GL rows start at the bottom, and bytes are R, G, B, A.
        const w = self.width;
        for (0..self.height / 2) |y| {
            const a = out[y * w ..][0..w];
            const b = out[(self.height - 1 - y) * w ..][0..w];
            for (a, b) |*p, *q| std.mem.swap(u32, p, q);
        }
        for (out[0 .. w * self.height]) |*p| {
            const bytes: [4]u8 = @bitCast(p.*);
            p.* = 0xFF000000 | (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2];
        }
    }

    const vtable: zui.Renderer.VTable = .{
        .begin = begin,
        .drawRect = drawRect,
        .drawText = drawText,
        .setClip = setClip,
        .end = end,
        .drawShadow = drawShadow,
        .drawPath = drawPath,
        .drawMesh = drawMesh,
        .drawImage = drawImage,
    };

    fn drawPath(ptr: *anyopaque, cmd: zui.PathCommand) void {
        const self = from(ptr);
        self.tess.path(cmd, self.scale) catch return;
        for (self.tess.triangles.items) |v| self.colorVertex(v.x, v.y, v.color);
    }

    fn drawMesh(ptr: *anyopaque, cmd: zui.MeshCommand) void {
        const self = from(ptr);
        var i: usize = 0;
        while (i + 2 < cmd.indices.len) : (i += 3) {
            for (cmd.indices[i..][0..3]) |index| if (index >= cmd.vertices.len) return;
            for (cmd.indices[i..][0..3]) |index| {
                const v = cmd.vertices[index];
                var x = v.pos.x * self.scale;
                var y = v.pos.y * self.scale;
                if (cmd.snap) {
                    x = @round(x);
                    y = @round(y);
                }
                self.colorVertex(x, y, v.color);
            }
        }
    }

    fn colorVertex(self: *GlRenderer, x: f32, y: f32, c: Color) void {
        self.vertices.append(self.allocator, .{
            .pos = .{ x, y },
            .local = .{ 0, 0 },
            .half = .{ 0, 0 },
            .params = .{ 0, 0, mode_color, 0 },
            .fill = .{ c.r, c.g, c.b, c.a },
            .border = .{ 0, 0, 0, 0 },
        }) catch {};
    }

    fn drawImage(ptr: *anyopaque, cmd: zui.ImageCommand) void {
        const self = from(ptr);
        const img = cmd.image;
        if (img.width == 0 or img.height == 0) return;
        const s = self.scale;
        // Edges snapped to pixels, as in the software renderer.
        const x0 = @round(cmd.rect.x * s);
        const y0 = @round(cmd.rect.y * s);
        const x1 = @round(cmd.rect.right() * s);
        const y1 = @round(cmd.rect.bottom() * s);
        if (x1 <= x0 or y1 <= y0) return;
        const tex = self.texture(img) orelse return;
        const filter = zui.Filter.resolve(cmd, x1 - x0);
        if (self.bound_image != img.id or self.bound_filter != filter) {
            self.flush();
            const gl = &self.gl;
            gl.ActiveTexture(GL_TEXTURE1);
            gl.BindTexture(GL_TEXTURE_2D, tex.name);
            const f: i32 = if (filter == .linear) GL_LINEAR else GL_NEAREST;
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
            gl.ActiveTexture(GL_TEXTURE0);
            self.bound_image = img.id;
            self.bound_filter = filter;
        }
        const uv = cmd.uv;
        const mode: f32 = if (img.format == .alpha8) mode_alpha_image else mode_image;
        self.quad(.{ x0, y0, x1, y1 }, .{ uv.x, uv.y, uv.right(), uv.bottom() }, .{ 0, 0 }, .{ 0, 0, mode, 0 }, cmd.tint, .transparent);
    }

    /// The texture holding `img`, uploaded now if it is new or changed.
    fn texture(self: *GlRenderer, img: *const zui.Image) ?*Texture {
        const gl = &self.gl;
        const entry = self.textures.getOrPut(self.allocator, img.id) catch return null;
        const t = entry.value_ptr;
        const fresh = !entry.found_existing;
        if (fresh) {
            t.* = .{ .name = 0, .version = img.version, .width = img.width, .height = img.height, .format = img.format };
            self.flush();
            gl.GenTextures(1, &t.name);
        }
        t.last_used = self.frame_number;
        const resized = t.width != img.width or t.height != img.height or t.format != img.format;
        if (!fresh and !resized and t.version == img.version) return t;
        // Queued quads sample whatever is bound to unit 1, which the upload
        // is about to change.
        self.flush();
        t.version = img.version;
        t.width = img.width;
        t.height = img.height;
        t.format = img.format;

        gl.ActiveTexture(GL_TEXTURE1);
        defer gl.ActiveTexture(GL_TEXTURE0);
        gl.BindTexture(GL_TEXTURE_2D, t.name);
        // Something else may be bound now; rebind before the next image.
        self.bound_image = 0;
        gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
        const w: i32 = @intCast(img.width);
        const h: i32 = @intCast(img.height);
        switch (img.format) {
            .alpha8 => gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, img.pixels.ptr),
            .argb32 => {
                // The shader blends premultiplied colors, and filtering
                // must too, or transparent pixels bleed dark edges.
                var data: [*]const u8 = img.pixels.ptr;
                if (!img.is_opaque) {
                    const n = @as(usize, img.width) * img.height;
                    self.upload.resize(self.allocator, n) catch return null;
                    // Row by row: no division per pixel.
                    for (0..img.height) |y| {
                        const row = self.upload.items[y * img.width ..][0..img.width];
                        for (row, 0..) |*d, x| d.* = premultiply(img.argbAt(@intCast(x), @intCast(y)));
                    }
                    data = @ptrCast(self.upload.items.ptr);
                }
                gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, data);
            },
        }
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        return t;
    }

    /// Drops textures of images not drawn for about five seconds at 60 fps.
    fn evictTextures(self: *GlRenderer) void {
        var it = self.textures.iterator();
        while (it.next()) |e| {
            if (self.frame_number - e.value_ptr.last_used < 300) continue;
            self.gl.DeleteTextures(1, &e.value_ptr.name);
            if (self.bound_image == e.key_ptr.*) self.bound_image = 0;
            self.textures.removeByPtr(e.key_ptr);
            // The iterator is invalid after a removal; the rest go next frame.
            return;
        }
    }

    fn from(ptr: *anyopaque) *GlRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(ptr: *anyopaque, frame: zui.Frame) void {
        const self = from(ptr);
        const gl = &self.gl;
        self.scale = frame.scale;
        self.width = @intFromFloat(@round(frame.width * frame.scale));
        self.height = @intFromFloat(@round(frame.height * frame.scale));
        self.vertices.clearRetainingCapacity();
        self.frame_number += 1;
        self.bound_image = 0;

        gl.Viewport(0, 0, @intCast(self.width), @intCast(self.height));
        gl.Disable(GL_DEPTH_TEST);
        gl.Disable(GL_CULL_FACE);
        gl.Disable(GL_SCISSOR_TEST);
        const c = self.clear_color;
        gl.ClearColor(unit(c.r), unit(c.g), unit(c.b), 1);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        gl.Enable(GL_BLEND);
        gl.BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); // premultiplied
        gl.UseProgram(self.program);
        gl.Uniform2f(self.viewport_uniform, @floatFromInt(self.width), @floatFromInt(self.height));
        gl.ActiveTexture(GL_TEXTURE0);
        gl.BindTexture(GL_TEXTURE_2D, self.atlas);
        gl.BindVertexArray(self.vao);
        gl.BindBuffer(GL_ARRAY_BUFFER, self.vbo);
    }

    fn end(ptr: *anyopaque) void {
        const self = from(ptr);
        self.flush();
        self.evictTextures();
    }

    fn setClip(ptr: *anyopaque, clip: ?Rect) void {
        const self = from(ptr);
        self.flush();
        const gl = &self.gl;
        const c = clip orelse return gl.Disable(GL_SCISSOR_TEST);
        // Rounded to whole pixels, as in the software renderer.
        const s = self.scale;
        const x0 = std.math.clamp(@round(c.x * s), 0, @as(f32, @floatFromInt(self.width)));
        const y0 = std.math.clamp(@round(c.y * s), 0, @as(f32, @floatFromInt(self.height)));
        const x1 = std.math.clamp(@round(c.right() * s), x0, @as(f32, @floatFromInt(self.width)));
        const y1 = std.math.clamp(@round(c.bottom() * s), y0, @as(f32, @floatFromInt(self.height)));
        gl.Enable(GL_SCISSOR_TEST);
        gl.Scissor(@intFromFloat(x0), @intCast(self.height - @as(u32, @intFromFloat(y1))), @intFromFloat(x1 - x0), @intFromFloat(y1 - y0));
    }

    fn drawRect(ptr: *anyopaque, cmd: zui.RectCommand) void {
        const self = from(ptr);
        if (cmd.fill.a == 0 and (cmd.border.a == 0 or cmd.border_width <= 0)) return;
        const s = self.scale;
        // Edges snapped to pixels, as in the software renderer.
        const x0 = @round(cmd.rect.x * s);
        const y0 = @round(cmd.rect.y * s);
        const x1 = @round(cmd.rect.right() * s);
        const y1 = @round(cmd.rect.bottom() * s);
        if (x1 <= x0 or y1 <= y0) return;
        const radius = std.math.clamp(cmd.radius * s, 0, @min(x1 - x0, y1 - y0) / 2);
        const border: f32 = if (cmd.border.a == 0) 0 else @max(0, cmd.border_width * s);
        // One pixel of margin for the anti-aliased edge.
        self.shapeQuad(x0, y0, x1, y1, 1, .{ radius, border, mode_rect, 0 }, cmd.fill, cmd.border);
    }

    fn drawShadow(ptr: *anyopaque, cmd: zui.ShadowCommand) void {
        const self = from(ptr);
        if (cmd.color.a == 0) return;
        const s = self.scale;
        const x0 = cmd.rect.x * s;
        const y0 = cmd.rect.y * s;
        const x1 = cmd.rect.right() * s;
        const y1 = cmd.rect.bottom() * s;
        if (x1 <= x0 or y1 <= y0) return;
        const radius = std.math.clamp(cmd.radius * s, 0, @min(x1 - x0, y1 - y0) / 2);
        const blur = @max(0.5, cmd.blur * s);
        self.shapeQuad(x0, y0, x1, y1, blur + 1, .{ radius, 0, mode_shadow, blur }, cmd.color, .transparent);
    }

    /// A quad covering the shape plus `margin`, carrying what the fragment
    /// shader needs to compute coverage.
    fn shapeQuad(self: *GlRenderer, x0: f32, y0: f32, x1: f32, y1: f32, margin: f32, params: [4]f32, fill: Color, border: Color) void {
        const cx = (x0 + x1) / 2;
        const cy = (y0 + y1) / 2;
        const half = [2]f32{ (x1 - x0) / 2, (y1 - y0) / 2 };
        const qx0 = x0 - margin;
        const qy0 = y0 - margin;
        const qx1 = x1 + margin;
        const qy1 = y1 + margin;
        self.quad(.{ qx0, qy0, qx1, qy1 }, .{ qx0 - cx, qy0 - cy, qx1 - cx, qy1 - cy }, half, params, fill, border);
    }

    fn drawText(ptr: *anyopaque, cmd: zui.TextCommand) void {
        const self = from(ptr);
        if (cmd.color.a == 0) return;
        // Pen positions exactly as the software renderer computes them.
        const size = cmd.size * self.scale;
        var pen_x = cmd.pos.x * self.scale;
        const baseline: i32 = roundToInt(cmd.pos.y * self.scale);
        var previous: ?u21 = null;
        var it: zui.Utf8Iterator = .{ .bytes = cmd.text };
        while (it.next()) |cp| {
            if (previous) |p| pen_x += cmd.font.kerning(p, cp, size);
            previous = cp;
            defer pen_x += cmd.font.advance(cp, size);

            const steps: f32 = zui.Font.subpixel_steps;
            const quantized = @floor(pen_x * steps + 0.5) / steps;
            const whole = @floor(quantized);
            const subpixel: u8 = @intFromFloat((quantized - whole) * steps);
            const slot = self.glyphSlot(cmd.font, cp, size, subpixel) orelse continue;
            if (slot.w == 0) continue;

            const left: f32 = @floatFromInt(roundToInt(whole) + slot.left);
            const top: f32 = @floatFromInt(baseline + slot.top);
            const w: f32 = @floatFromInt(slot.w);
            const h: f32 = @floatFromInt(slot.h);
            const u: f32 = @floatFromInt(slot.x);
            const v: f32 = @floatFromInt(slot.y);
            self.quad(.{ left, top, left + w, top + h }, .{ u, v, u + w, v + h }, .{ 0, 0 }, .{ 0, 0, mode_glyph, 0 }, cmd.color, .transparent);
        }
    }

    /// Finds or uploads a glyph's bitmap in the atlas.
    fn glyphSlot(self: *GlRenderer, font: *zui.Font, cp: u21, size: f32, subpixel: u8) ?AtlasSlot {
        const key: GlyphKey = .{
            .font = font.id,
            .codepoint = cp,
            .size_q = @intFromFloat(std.math.clamp(size * 4, 1, 60000)),
            .subpixel = subpixel,
        };
        if (self.glyphs.get(key)) |slot| return slot;
        const glyph = font.glyph(cp, size, subpixel) catch return null;
        var slot: AtlasSlot = .{ .w = @intCast(glyph.width), .h = @intCast(glyph.height), .left = glyph.left, .top = glyph.top };
        // A glyph bigger than the whole atlas can never fit: skip it rather
        // than wipe the atlas (and upload every other glyph again) each frame.
        if (glyph.width > atlas_size or glyph.height > atlas_size) return null;
        if (glyph.width > 0) {
            const at = self.shelf.place(glyph.width, glyph.height) orelse blk: {
                // Full: start over. Glyphs already queued this frame still
                // point at the old contents, so draw them first.
                self.flush();
                self.glyphs.clearRetainingCapacity();
                self.shelf = .{};
                break :blk self.shelf.place(glyph.width, glyph.height) orelse return null;
            };
            slot.x = at[0];
            slot.y = at[1];
            const gl = &self.gl;
            gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
            gl.TexSubImage2D(GL_TEXTURE_2D, 0, slot.x, slot.y, slot.w, slot.h, GL_RED, GL_UNSIGNED_BYTE, glyph.coverage.ptr);
        }
        self.glyphs.put(self.allocator, key, slot) catch return null;
        return slot;
    }

    fn quad(self: *GlRenderer, pos: [4]f32, local: [4]f32, half: [2]f32, params: [4]f32, fill: Color, border: Color) void {
        const f = [4]u8{ fill.r, fill.g, fill.b, fill.a };
        const b = [4]u8{ border.r, border.g, border.b, border.a };
        const corners = [6][2]u1{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const out = self.vertices.addManyAsArray(self.allocator, 6) catch return;
        for (out, corners) |*v, c| v.* = .{
            .pos = .{ pos[@as(usize, c[0]) * 2], pos[@as(usize, c[1]) * 2 + 1] },
            .local = .{ local[@as(usize, c[0]) * 2], local[@as(usize, c[1]) * 2 + 1] },
            .half = half,
            .params = params,
            .fill = f,
            .border = b,
        };
    }

    fn flush(self: *GlRenderer) void {
        const n = self.vertices.items.len;
        if (n == 0) return;
        const gl = &self.gl;
        gl.BufferData(GL_ARRAY_BUFFER, @intCast(n * @sizeOf(Vertex)), self.vertices.items.ptr, GL_STREAM_DRAW);
        gl.DrawArrays(GL_TRIANGLES, 0, @intCast(n));
        self.vertices.clearRetainingCapacity();
    }
};

const mode_rect: f32 = 0;
const mode_glyph: f32 = 1;
const mode_shadow: f32 = 2;
const mode_color: f32 = 3;
const mode_image: f32 = 4;
const mode_alpha_image: f32 = 5;

/// An image's GPU copy.
const Texture = struct {
    name: u32,
    version: u32,
    width: u32,
    height: u32,
    format: zui.Image.Format,
    last_used: u64 = 0,
};

fn premultiply(p: u32) u32 {
    const a = p >> 24;
    const r = ((p >> 16) & 0xFF) * a / 255;
    const g = ((p >> 8) & 0xFF) * a / 255;
    const b = (p & 0xFF) * a / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

const Vertex = extern struct {
    /// Framebuffer pixels, y down.
    pos: [2]f32,
    /// Offset from the shape's center in pixels, or the atlas texel for glyphs.
    local: [2]f32,
    /// Half the shape's size in pixels.
    half: [2]f32,
    /// Radius, border width, mode, blur.
    params: [4]f32,
    fill: [4]u8,
    border: [4]u8,
};

const GlyphKey = struct { font: u32, codepoint: u21, size_q: u16, subpixel: u8 };

const AtlasSlot = struct { x: i32 = 0, y: i32 = 0, w: i32, h: i32, left: i32, top: i32 };

/// Packs glyphs into rows of the atlas.
const Shelf = struct {
    x: u32 = 0,
    y: u32 = 0,
    row_h: u32 = 0,

    const gap = 1;

    fn place(self: *Shelf, w: u32, h: u32) ?[2]i32 {
        const size = GlRenderer.atlas_size;
        if (w + gap > size or h + gap > size) return null;
        if (self.x + w + gap > size) {
            self.x = 0;
            self.y += self.row_h + gap;
            self.row_h = 0;
        }
        if (self.y + h + gap > size) return null;
        const at = [2]i32{ @intCast(self.x), @intCast(self.y) };
        self.x += w + gap;
        self.row_h = @max(self.row_h, h);
        return at;
    }
};

const vertex_source =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_local;
    \\layout(location = 2) in vec2 a_half;
    \\layout(location = 3) in vec4 a_params;
    \\layout(location = 4) in vec4 a_fill;
    \\layout(location = 5) in vec4 a_border;
    \\uniform vec2 viewport;
    \\out vec2 v_local;
    \\flat out vec2 v_half;
    \\flat out vec4 v_params;
    \\out vec4 v_fill;
    \\flat out vec4 v_border;
    \\void main() {
    \\    vec2 ndc = a_pos / viewport * 2.0 - 1.0;
    \\    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    \\    v_local = a_local;
    \\    v_half = a_half;
    \\    v_params = a_params;
    \\    v_fill = a_fill;
    \\    v_border = a_border;
    \\}
;

// The distance and coverage functions mirror `Shape` in software.zig.
const fragment_source =
    \\#version 330 core
    \\in vec2 v_local;
    \\flat in vec2 v_half;
    \\flat in vec4 v_params;
    \\in vec4 v_fill;
    \\flat in vec4 v_border;
    \\uniform sampler2D atlas;
    \\uniform sampler2D image;
    \\out vec4 color;
    \\float box(vec2 p, vec2 half_size, float radius, float inset) {
    \\    vec2 h = half_size - inset;
    \\    float r = max(0.0, radius - inset);
    \\    vec2 q = abs(p) - (h - r);
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\float coverage(float d) { return clamp(0.5 - d, 0.0, 1.0); }
    \\void main() {
    \\    int mode = int(v_params.z + 0.5);
    \\    if (mode == 3) { color = vec4(v_fill.rgb * v_fill.a, v_fill.a); return; }
    \\    if (mode == 4) {
    \\        // The texture is premultiplied; so is the tint below.
    \\        color = texture(image, v_local) * vec4(v_fill.rgb * v_fill.a, v_fill.a);
    \\        return;
    \\    }
    \\    if (mode == 5) {
    \\        float a = texture(image, v_local).r * v_fill.a;
    \\        color = vec4(v_fill.rgb * a, a);
    \\        return;
    \\    }
    \\    if (mode == 1) {
    \\        float a = texelFetch(atlas, ivec2(floor(v_local)), 0).r * v_fill.a;
    \\        color = vec4(v_fill.rgb * a, a);
    \\        return;
    \\    }
    \\    float d = box(v_local, v_half, v_params.x, 0.0);
    \\    if (mode == 2) {
    \\        float t = clamp(d / v_params.w, 0.0, 1.0);
    \\        float a = (d <= 0.0 ? 1.0 : 1.0 - t * t * (3.0 - 2.0 * t)) * v_fill.a;
    \\        color = vec4(v_fill.rgb * a, a);
    \\        return;
    \\    }
    \\    float outer = coverage(d);
    \\    float border = v_params.y;
    \\    float inner = border > 0.0 ? coverage(box(v_local, v_half, v_params.x, border)) : outer;
    \\    // Fill, then the border ring over it, as one premultiplied color.
    \\    float af = v_fill.a * inner;
    \\    float ab = border > 0.0 ? v_border.a * max(outer - inner, 0.0) : 0.0;
    \\    vec3 rgb = v_border.rgb * ab + v_fill.rgb * af * (1.0 - ab);
    \\    color = vec4(rgb, ab + af * (1.0 - ab));
    \\}
;

fn buildProgram(gl: *const Gl) Error!u32 {
    const vs = try compile(gl, GL_VERTEX_SHADER, vertex_source);
    defer gl.DeleteShader(vs);
    const fs = try compile(gl, GL_FRAGMENT_SHADER, fragment_source);
    defer gl.DeleteShader(fs);
    const program = gl.CreateProgram();
    gl.AttachShader(program, vs);
    gl.AttachShader(program, fs);
    gl.LinkProgram(program);
    var ok: i32 = 0;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var len: i32 = 0;
        gl.GetProgramInfoLog(program, log.len, &len, &log);
        std.log.err("GL program link failed: {s}", .{log[0..@intCast(len)]});
        return error.ShaderFailed;
    }
    return program;
}

fn compile(gl: *const Gl, kind: u32, source: [:0]const u8) Error!u32 {
    const shader = gl.CreateShader(kind);
    const sources = [_][*:0]const u8{source.ptr};
    gl.ShaderSource(shader, 1, &sources, null);
    gl.CompileShader(shader);
    var ok: i32 = 0;
    gl.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var len: i32 = 0;
        gl.GetShaderInfoLog(shader, log.len, &len, &log);
        std.log.err("GL shader compile failed: {s}", .{log[0..@intCast(len)]});
        gl.DeleteShader(shader);
        return error.ShaderFailed;
    }
    return shader;
}

fn unit(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255;
}

fn roundToInt(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@round(v), -1e9, 1e9));
}

const GL_COLOR_BUFFER_BIT = 0x4000;
const GL_BLEND = 0x0BE2;
const GL_ONE = 1;
const GL_ONE_MINUS_SRC_ALPHA = 0x0303;
const GL_SCISSOR_TEST = 0x0C11;
const GL_DEPTH_TEST = 0x0B71;
const GL_CULL_FACE = 0x0B44;
const GL_TRIANGLES = 0x0004;
const GL_ARRAY_BUFFER = 0x8892;
const GL_STREAM_DRAW = 0x88E0;
const GL_FLOAT = 0x1406;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_FALSE: u8 = 0;
const GL_TRUE: u8 = 1;
const GL_VERTEX_SHADER = 0x8B31;
const GL_FRAGMENT_SHADER = 0x8B30;
const GL_COMPILE_STATUS = 0x8B81;
const GL_LINK_STATUS = 0x8B82;
const GL_TEXTURE_2D = 0x0DE1;
const GL_TEXTURE0 = 0x84C0;
const GL_TEXTURE1 = 0x84C1;
const GL_LINEAR = 0x2601;
const GL_RGBA8 = 0x8058;
const GL_BGRA = 0x80E1;
const GL_UNSIGNED_INT_8_8_8_8_REV = 0x8367;
const GL_R8 = 0x8229;
const GL_RED = 0x1903;
const GL_RGBA = 0x1908;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_NEAREST = 0x2600;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
const GL_PACK_ALIGNMENT = 0x0D05;

/// The GL entry points this renderer uses, loaded at runtime.
const Gl = struct {
    Viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    ClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    Clear: *const fn (u32) callconv(.c) void,
    Enable: *const fn (u32) callconv(.c) void,
    Disable: *const fn (u32) callconv(.c) void,
    BlendFunc: *const fn (u32, u32) callconv(.c) void,
    Scissor: *const fn (i32, i32, i32, i32) callconv(.c) void,
    GenVertexArrays: *const fn (i32, *u32) callconv(.c) void,
    DeleteVertexArrays: *const fn (i32, *const u32) callconv(.c) void,
    BindVertexArray: *const fn (u32) callconv(.c) void,
    GenBuffers: *const fn (i32, *u32) callconv(.c) void,
    DeleteBuffers: *const fn (i32, *const u32) callconv(.c) void,
    BindBuffer: *const fn (u32, u32) callconv(.c) void,
    BufferData: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void,
    EnableVertexAttribArray: *const fn (u32) callconv(.c) void,
    VertexAttribPointer: *const fn (u32, i32, u32, u8, i32, ?*const anyopaque) callconv(.c) void,
    CreateShader: *const fn (u32) callconv(.c) u32,
    DeleteShader: *const fn (u32) callconv(.c) void,
    ShaderSource: *const fn (u32, i32, [*]const [*:0]const u8, ?[*]const i32) callconv(.c) void,
    CompileShader: *const fn (u32) callconv(.c) void,
    GetShaderiv: *const fn (u32, u32, *i32) callconv(.c) void,
    GetShaderInfoLog: *const fn (u32, i32, *i32, [*]u8) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) u32,
    DeleteProgram: *const fn (u32) callconv(.c) void,
    AttachShader: *const fn (u32, u32) callconv(.c) void,
    LinkProgram: *const fn (u32) callconv(.c) void,
    GetProgramiv: *const fn (u32, u32, *i32) callconv(.c) void,
    GetProgramInfoLog: *const fn (u32, i32, *i32, [*]u8) callconv(.c) void,
    UseProgram: *const fn (u32) callconv(.c) void,
    GetUniformLocation: *const fn (u32, [*:0]const u8) callconv(.c) i32,
    Uniform2f: *const fn (i32, f32, f32) callconv(.c) void,
    Uniform1i: *const fn (i32, i32) callconv(.c) void,
    DrawArrays: *const fn (u32, i32, i32) callconv(.c) void,
    GenTextures: *const fn (i32, *u32) callconv(.c) void,
    DeleteTextures: *const fn (i32, *const u32) callconv(.c) void,
    BindTexture: *const fn (u32, u32) callconv(.c) void,
    ActiveTexture: *const fn (u32) callconv(.c) void,
    TexImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void,
    TexSubImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void,
    TexParameteri: *const fn (u32, u32, i32) callconv(.c) void,
    PixelStorei: *const fn (u32, i32) callconv(.c) void,
    ReadPixels: *const fn (i32, i32, i32, i32, u32, u32, ?*anyopaque) callconv(.c) void,

    fn load(loader: Loader) Error!Gl {
        var gl: Gl = undefined;
        inline for (comptime std.meta.fieldNames(Gl)) |name| {
            const ptr = loader("gl" ++ name) orelse {
                std.log.err("OpenGL function gl{s} is missing", .{name});
                return error.MissingGlFunction;
            };
            @field(gl, name) = @ptrCast(@alignCast(ptr));
        }
        return gl;
    }
};

test "the shelf packs rows and reports when full" {
    var shelf: Shelf = .{};
    const a = shelf.place(10, 12).?;
    const b = shelf.place(10, 8).?;
    try std.testing.expectEqual([2]i32{ 0, 0 }, a);
    try std.testing.expectEqual([2]i32{ 11, 0 }, b);
    const wide = shelf.place(GlRenderer.atlas_size - 20, 5).?;
    try std.testing.expectEqual([2]i32{ 0, 13 }, wide);
    try std.testing.expectEqual(@as(?[2]i32, null), shelf.place(GlRenderer.atlas_size + 1, 1));
}
