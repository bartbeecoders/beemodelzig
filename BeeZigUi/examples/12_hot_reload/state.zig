//! The app's state. It lives in the host, outside both the `Ui` and the
//! reloadable library, so a reload keeps every value. Shared by host.zig and
//! app.zig; change it only with both stopped, since its layout is a contract.

const zui = @import("zui");

/// Everything the app remembers.
pub const State = struct {
    count: i32 = 0,
    speed: f32 = 0.5,
    enabled: bool = true,
    note_buffer: [64]u8 = undefined,
    note_len: usize = 0,
    /// How many times the host has reloaded the library.
    reloads: u32 = 0,
    show_window: bool = true,
};

/// What the library exports: describe one frame.
pub const FrameFn = *const fn (ui: *zui.Ui, state: *State) callconv(.c) void;

/// The exported symbol's name.
pub const frame_symbol = "hotFrame";
