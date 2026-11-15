// Keyboard navigation (a11y.s): Tab / Shift+Tab move a focus ring through the
// widgets of the open dialog, picker or overlay, or else of the active area
// (not over a 3D viewport, where Tab is edit mode); Enter / Space work the
// focused widget, the arrows step a number, Esc lets go.
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const wl = @import("wayland.zig");
const wg = @import("wg.zig");
const app = @import("app.zig");

/// A key press: was it the keyboard's navigation? (`key`: the letter on the key.)
pub fn key(cv: *gfx.Canvas, code: u32) bool {
    const K = ui.KEY;
    if (code == K.TAB) {
        if (ui.mods & (wl.MOD_CTRL | wl.MOD_ALT) != 0) return false;
        const s = app.focusScope() orelse return false;
        // typing: confirm it, then the next field
        if (ui.edit_id != 0) {
            ui.edit_submit = true;
            app.hitNow(cv);
            wg.afterPass();
        }
        if (!wg.step(if (ui.shift()) -1 else 1, s)) return false;
        app.dirty = true;
        return true;
    }
    if (wg.kfocus == 0 or ui.edit_id != 0) return false;
    if (wg.focused() == null) return false;
    switch (code) {
        K.ENTER, K.KPENTER, K.SPACE => {
            wg.activate();
            app.hitNow(cv);
            ui.active = 0;
        },
        K.ESC => wg.kfocus = 0,
        K.RIGHT, K.UP => wg.nudge(1),
        K.LEFT, K.DOWN => wg.nudge(-1),
        else => return false,
    }
    app.dirty = true;
    return true;
}
