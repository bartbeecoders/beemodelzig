//! A native Windows backend with no C runtime: user32, gdi32, kernel32 and
//! shell32 called directly. The software renderer's pixels are shown with
//! SetDIBitsToDevice; the window frame is the system's.
//!
//!     var window: win32.Window = undefined;
//!     try window.init(gpa, .{ .title = "My tool" });
//!     defer window.deinit();
//!     ui.clipboard = window.clipboard();
//!     while (!window.close_requested) {
//!         _ = window.wait(&ui.input, if (ui.redraw_requested) 0 else -1);
//!         const size = window.size();
//!         ui.beginFrame(.{ .width = size.width, .height = size.height, .dt = dt });
//!         ... describe the UI ...
//!         window.present(&ui, try ui.endFrame());
//!     }
//!
//! Per-monitor DPI aware: the scale follows the monitor the window is on.
//! Compile-checked only: it has not been run on Windows yet.

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const software = @import("zui_software");
const Allocator = std.mem.Allocator;

const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;

const HWND = ?*opaque {};
const HINSTANCE = ?*opaque {};
const HDC = ?*opaque {};
const HCURSOR = ?*opaque {};
const HANDLE = ?*anyopaque;
const HDROP = ?*opaque {};
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const BOOL = i32;
const UINT = u32;
const DWORD = u32;
const ATOM = u16;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: HCURSOR = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MSG = extern struct { hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: POINT, lPrivate: DWORD };

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};
const BITMAPINFO = extern struct { bmiHeader: BITMAPINFOHEADER, bmiColors: [1]u32 = .{0} };
const PAINTSTRUCT = extern struct { hdc: HDC, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) ATOM;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const u16, [*:0]const u16, DWORD, i32, i32, i32, i32, HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(WINAPI) HWND;
extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;
extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) BOOL;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PeekMessageW(*MSG, HWND, UINT, UINT, UINT) callconv(WINAPI) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn MsgWaitForMultipleObjects(DWORD, ?*const HANDLE, BOOL, DWORD, DWORD) callconv(WINAPI) DWORD;
extern "user32" fn GetDC(HWND) callconv(WINAPI) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(WINAPI) i32;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(WINAPI) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(WINAPI) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) BOOL;
extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, UINT) callconv(WINAPI) BOOL;
extern "user32" fn LoadCursorW(HINSTANCE, usize) callconv(WINAPI) HCURSOR;
extern "user32" fn SetCursor(HCURSOR) callconv(WINAPI) HCURSOR;
extern "user32" fn GetKeyState(i32) callconv(WINAPI) i16;
extern "user32" fn SetCapture(HWND) callconv(WINAPI) HWND;
extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) UINT;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(WINAPI) BOOL;
extern "user32" fn OpenClipboard(HWND) callconv(WINAPI) BOOL;
extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) HANDLE;
extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(WINAPI) HANDLE;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(WINAPI) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) isize;
extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(WINAPI) BOOL;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(WINAPI) BOOL;
extern "gdi32" fn SetDIBitsToDevice(HDC, i32, i32, DWORD, DWORD, i32, i32, UINT, UINT, *const anyopaque, *const BITMAPINFO, UINT) callconv(WINAPI) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) HINSTANCE;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn GlobalFree(HANDLE) callconv(WINAPI) HANDLE;
extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(WINAPI) void;
extern "shell32" fn DragQueryFileW(HDROP, UINT, ?[*]u16, UINT) callconv(WINAPI) UINT;
extern "shell32" fn DragQueryPoint(HDROP, *POINT) callconv(WINAPI) BOOL;
extern "shell32" fn DragFinish(HDROP) callconv(WINAPI) void;

const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_SETFOCUS = 0x0007;
const WM_PAINT = 0x000F;
const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_SETCURSOR = 0x0020;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_LBUTTONDBLCLK = 0x0203;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_RBUTTONDBLCLK = 0x0206;
const WM_MBUTTONDBLCLK = 0x0209;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020A;
const WM_MOUSEHWHEEL = 0x020E;
const WM_DROPFILES = 0x0233;
const WM_DPICHANGED = 0x02E0;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const WS_EX_ACCEPTFILES = 0x00000010;
const CS_DBLCLKS = 0x0008;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const PM_REMOVE = 1;
const QS_ALLINPUT = 0x04FF;
const INFINITE: DWORD = 0xFFFFFFFF;
const CF_UNICODETEXT = 13;
const GMEM_MOVEABLE = 0x0002;
const GWLP_USERDATA = -21;
const HTCLIENT = 1;
const SWP_NOZORDER = 0x0004;
const SWP_NOACTIVATE = 0x0010;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

/// Settings for `Window.init`.
pub const Options = struct {
    title: []const u8 = "Zui",
    width: u32 = 960,
    height: u32 = 640,
};

/// Why the window could not open.
pub const Error = error{ RegisterClassFailed, CreateWindowFailed, OutOfMemory };

/// A top-level window drawn by the software renderer.
pub const Window = struct {
    gpa: Allocator,
    hwnd: HWND = null,
    sw: software.SoftwareRenderer,
    /// Where events go; set by `wait`.
    input: ?*zui.Input = null,
    close_requested: bool = false,
    /// Client size in pixels, and pixels per unit.
    pixel_w: u32 = 0,
    pixel_h: u32 = 0,
    scale: f32 = 1,
    cursor: zui.Cursor = .default,
    high_surrogate: u16 = 0,
    buttons_down: u8 = 0,
    clip_text: std.ArrayList(u8) = .empty,

    /// Opens the window.
    pub fn init(self: *Window, gpa: Allocator, options: Options) Error!void {
        self.* = .{ .gpa = gpa, .sw = .init(gpa) };
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const instance = GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZuiWindow");
        const class: WNDCLASSEXW = .{
            .style = CS_DBLCLKS,
            .lpfnWndProc = windowProc,
            .hInstance = instance,
            .hCursor = LoadCursorW(null, 32512),
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&class);
        var title: [256:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&title, options.title[0..@min(options.title.len, 200)]) catch 0;
        title[n] = 0;
        self.hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, class_name, &title, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, @intCast(options.width), @intCast(options.height), null, null, instance, null);
        if (self.hwnd == null) return error.CreateWindowFailed;
        _ = SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, @intCast(@intFromPtr(self)));
        // The size asked for is the client area at this monitor's scale.
        const dpi = GetDpiForWindow(self.hwnd);
        self.scale = @as(f32, @floatFromInt(@max(dpi, 96))) / 96;
        var r: RECT = .{ .left = 0, .top = 0, .right = @intFromFloat(@as(f32, @floatFromInt(options.width)) * self.scale), .bottom = @intFromFloat(@as(f32, @floatFromInt(options.height)) * self.scale) };
        _ = AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, 0, WS_EX_ACCEPTFILES, dpi);
        _ = SetWindowPos(self.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, 0x0002 | SWP_NOZORDER | SWP_NOACTIVATE);
        DragAcceptFiles(self.hwnd, 1);
        _ = ShowWindow(self.hwnd, 5);
        self.updateSize();
    }

    /// Closes the window.
    pub fn deinit(self: *Window) void {
        if (self.hwnd != null) _ = DestroyWindow(self.hwnd);
        self.sw.deinit();
        self.clip_text.deinit(self.gpa);
    }

    fn updateSize(self: *Window) void {
        var r: RECT = undefined;
        if (GetClientRect(self.hwnd, &r) == 0) return;
        self.pixel_w = @intCast(@max(1, r.right - r.left));
        self.pixel_h = @intCast(@max(1, r.bottom - r.top));
    }

    /// The client area in units, for `Ui.beginFrame`, and its scale.
    pub fn size(self: *const Window) struct { width: f32, height: f32, scale: f32 } {
        return .{ .width = @as(f32, @floatFromInt(self.pixel_w)) / self.scale, .height = @as(f32, @floatFromInt(self.pixel_h)) / self.scale, .scale = self.scale };
    }

    /// Waits up to `timeout_ms` (-1: until something happens) and feeds
    /// the messages into `input`. True if any arrived.
    pub fn wait(self: *Window, input: *zui.Input, timeout_ms: i32) bool {
        self.input = input;
        defer self.input = null;
        var msg: MSG = undefined;
        var got = false;
        if (PeekMessageW(&msg, null, 0, 0, 0) == 0 and timeout_ms != 0) {
            _ = MsgWaitForMultipleObjects(0, null, 0, if (timeout_ms < 0) INFINITE else @intCast(timeout_ms), QS_ALLINPUT);
        }
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
            got = true;
        }
        return got;
    }

    /// Renders the frame and shows it.
    pub fn present(self: *Window, ui: *zui.Ui, list: *const zui.DrawList) void {
        self.sw.resize(self.pixel_w, self.pixel_h) catch return;
        self.sw.clear_color = ui.style.colors.background;
        const frame = ui.renderFrame(self.scale);
        self.sw.renderer().render(list, frame);
        if (ui.sample_request) |p| {
            if (self.sw.pixelAt(@intFromFloat(p.x * frame.scale), @intFromFloat(p.y * frame.scale))) |c| {
                if (ui.input.onColorSample(c)) ui.requestRedraw();
            }
        }
        self.cursor = ui.cursor;
        const dc = GetDC(self.hwnd);
        defer _ = ReleaseDC(self.hwnd, dc);
        self.blit(dc);
    }

    fn blit(self: *Window, dc: HDC) void {
        if (self.sw.width == 0) return;
        // 32-bit BGRA rows, top-down (a negative height).
        const info: BITMAPINFO = .{ .bmiHeader = .{ .biWidth = @intCast(self.sw.width), .biHeight = -@as(i32, @intCast(self.sw.height)) } };
        _ = SetDIBitsToDevice(dc, 0, 0, self.sw.width, self.sw.height, 0, 0, 0, self.sw.height, self.sw.pixels.ptr, &info, 0);
    }

    /// The system clipboard, for `Ui.clipboard`.
    pub fn clipboard(self: *Window) zui.Clipboard {
        return .{ .context = self, .getFn = getClipboard, .setFn = setClipboard };
    }

    fn getClipboard(context: *anyopaque) []const u8 {
        const self: *Window = @ptrCast(@alignCast(context));
        self.clip_text.clearRetainingCapacity();
        if (OpenClipboard(self.hwnd) == 0) return "";
        defer _ = CloseClipboard();
        const h = GetClipboardData(CF_UNICODETEXT) orelse return "";
        const p: [*:0]const u16 = @ptrCast(@alignCast(GlobalLock(h) orelse return ""));
        defer _ = GlobalUnlock(h);
        const wide = std.mem.span(p);
        var it = std.unicode.Utf16LeIterator.init(wide);
        while (it.nextCodepoint() catch null) |cp| {
            if (cp == '\r') continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            self.clip_text.appendSlice(self.gpa, buf[0..n]) catch break;
        }
        return self.clip_text.items;
    }

    fn setClipboard(context: *anyopaque, text: []const u8) void {
        const self: *Window = @ptrCast(@alignCast(context));
        if (OpenClipboard(self.hwnd) == 0) return;
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        const units = std.unicode.calcUtf16LeLen(text) catch return;
        const h = GlobalAlloc(GMEM_MOVEABLE, (units + 1) * 2) orelse return;
        const p: [*]u16 = @ptrCast(@alignCast(GlobalLock(h) orelse {
            _ = GlobalFree(h);
            return;
        }));
        const n = std.unicode.utf8ToUtf16Le(p[0..units], text) catch 0;
        p[n] = 0;
        _ = GlobalUnlock(h);
        if (SetClipboardData(CF_UNICODETEXT, h) == null) _ = GlobalFree(h);
    }

    fn modifiers() zui.Modifiers {
        const down = struct {
            fn f(vk: i32) bool {
                return GetKeyState(vk) < 0;
            }
        }.f;
        return .{ .shift = down(0x10), .ctrl = down(0x11), .alt = down(0x12), .super = down(0x5B) or down(0x5C) };
    }

    fn handle(self: *Window, msg: UINT, wp: WPARAM, lp: LPARAM) ?LRESULT {
        const in = self.input;
        const pos: zui.Vec2 = .{
            .x = @as(f32, @floatFromInt(@as(i16, @truncate(lp)))) / self.scale,
            .y = @as(f32, @floatFromInt(@as(i16, @truncate(lp >> 16)))) / self.scale,
        };
        switch (msg) {
            WM_CLOSE => {
                self.close_requested = true;
                return 0;
            },
            WM_DESTROY => return 0,
            WM_SIZE => {
                self.updateSize();
                return 0;
            },
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                var ps: PAINTSTRUCT = undefined;
                const dc = BeginPaint(self.hwnd, &ps);
                self.blit(dc);
                _ = EndPaint(self.hwnd, &ps);
                return 0;
            },
            WM_DPICHANGED => {
                self.scale = @as(f32, @floatFromInt(wp & 0xFFFF)) / 96;
                const r: *const RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                _ = SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                self.updateSize();
                return 0;
            },
            WM_SETCURSOR => {
                if (lp & 0xFFFF != HTCLIENT) return null;
                const id: usize = switch (self.cursor) {
                    .default => 32512,
                    .text => 32513,
                    .crosshair => 32515,
                    .resize_nwse => 32642,
                    .resize_nesw => 32643,
                    .resize_ew => 32644,
                    .resize_ns => 32645,
                    .move => 32646,
                    .not_allowed => 32648,
                    // (no hands: the link hand, the four arrows)
                    .pointer, .grab => 32649,
                    .grabbing => 32646,
                };
                _ = SetCursor(LoadCursorW(null, id));
                return 1;
            },
            WM_MOUSEMOVE => if (in) |i| i.onMouseMove(pos),
            // (CS_DBLCLKS turns the second press of each button into its DBLCLK message)
            WM_LBUTTONDOWN, WM_LBUTTONDBLCLK, WM_RBUTTONDOWN, WM_RBUTTONDBLCLK, WM_MBUTTONDOWN, WM_MBUTTONDBLCLK, WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP => {
                const down = msg == WM_LBUTTONDOWN or msg == WM_LBUTTONDBLCLK or msg == WM_RBUTTONDOWN or msg == WM_RBUTTONDBLCLK or msg == WM_MBUTTONDOWN or msg == WM_MBUTTONDBLCLK;
                const button: zui.MouseButton = switch (msg) {
                    WM_RBUTTONDOWN, WM_RBUTTONDBLCLK, WM_RBUTTONUP => .right,
                    WM_MBUTTONDOWN, WM_MBUTTONDBLCLK, WM_MBUTTONUP => .middle,
                    else => .left,
                };
                // Keep the pointer while a button is held outside the window.
                if (down) {
                    if (self.buttons_down == 0) _ = SetCapture(self.hwnd);
                    self.buttons_down += 1;
                } else {
                    self.buttons_down -|= 1;
                    if (self.buttons_down == 0) _ = ReleaseCapture();
                }
                if (in) |i| {
                    i.onMouseMove(pos);
                    i.onMouseButtonClicks(button, down, if (msg == WM_LBUTTONDBLCLK or msg == WM_RBUTTONDBLCLK or msg == WM_MBUTTONDBLCLK) 2 else 1);
                }
                return 0;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => if (in) |i| {
                const delta = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))))) / 120;
                if (msg == WM_MOUSEWHEEL) i.onScroll(.{ .x = 0, .y = delta }) else i.onScroll(.{ .x = -delta, .y = 0 });
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => if (in) |i| {
                i.modifiers = modifiers();
                if (keyFromVk(@truncate(wp))) |k| {
                    if (msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN) i.onKeyPress(k) else i.onKeyRelease(k);
                }
                // Alt+F4 and the system menu still work.
                if (msg == WM_SYSKEYDOWN or msg == WM_SYSKEYUP) return null;
                return 0;
            },
            WM_CHAR => if (in) |i| {
                const unit: u16 = @truncate(wp);
                if (unit >= 0xD800 and unit < 0xDC00) {
                    self.high_surrogate = unit;
                    return 0;
                }
                var cp: u21 = unit;
                if (unit >= 0xDC00 and unit < 0xE000 and self.high_surrogate != 0) {
                    cp = 0x10000 + ((@as(u21, self.high_surrogate) - 0xD800) << 10) + (unit - 0xDC00);
                    self.high_surrogate = 0;
                }
                if (cp < 0x20 or cp == 0x7F) return 0;
                // Ctrl+letter makes control characters, not text.
                if (i.modifiers.ctrl and !i.modifiers.alt) return 0;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return 0;
                i.onText(buf[0..n]);
                return 0;
            },
            WM_DROPFILES => if (in) |i| {
                const drop: HDROP = @ptrFromInt(wp);
                defer DragFinish(drop);
                var pt: POINT = undefined;
                _ = DragQueryPoint(drop, &pt);
                const at: zui.Vec2 = .{ .x = @as(f32, @floatFromInt(pt.x)) / self.scale, .y = @as(f32, @floatFromInt(pt.y)) / self.scale };
                const count = DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
                for (0..count) |k| {
                    var wide: [1024]u16 = undefined;
                    const len = DragQueryFileW(drop, @intCast(k), &wide, wide.len);
                    var utf8: [3072]u8 = undefined;
                    const n = std.unicode.utf16LeToUtf8(&utf8, wide[0..len]) catch continue;
                    i.onFileDrop(utf8[0..n], at);
                }
                return 0;
            },
            else => {},
        }
        return null;
    }
};

fn windowProc(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    const p = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p != 0) {
        const self: *Window = @ptrFromInt(@as(usize, @bitCast(p)));
        if (self.handle(msg, wp, lp)) |r| return r;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/// The Zui key for a virtual-key code.
pub fn keyFromVk(vk: u8) ?zui.Key {
    return switch (vk) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2D => .insert,
        0x2E => .delete,
        0x30...0x39 => @enumFromInt(@intFromEnum(zui.Key.@"0") + (vk - 0x30)),
        0x41...0x5A => @enumFromInt(@intFromEnum(zui.Key.a) + (vk - 0x41)),
        0x70...0x7B => @enumFromInt(@intFromEnum(zui.Key.f1) + (vk - 0x70)),
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        else => null,
    };
}

test "virtual keys" {
    try std.testing.expectEqual(zui.Key.a, keyFromVk(0x41).?);
    try std.testing.expectEqual(zui.Key.@"7", keyFromVk(0x37).?);
    try std.testing.expectEqual(zui.Key.f12, keyFromVk(0x7B).?);
    try std.testing.expect(keyFromVk(0x10) == null);
}
