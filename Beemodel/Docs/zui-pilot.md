# Zui pilot: the Preferences drawn by Zui

> **History.** This page records the pilot as it was run. Since milestone M0 of
> [beezigui-migration.html](beezigui-migration.html) (2026-11-14) there is no
> `-Dzui` flag: BeeZigUi is a required path dependency (`../BeeZigUi`, in
> `build.zig.zon`), `zig build` always draws the Preferences with Zui, and the
> pilot's general parts (fonts, style, input, frames, record) moved from
> `src/zuiprefs.zig` to `src/zuihost.zig`. The build commands below are the
> pilot's and no longer work.

A trial of Zui (`../../Zig/beezigui`) inside BeeModel, behind a build flag.
Without the flag nothing of Zui is built or linked, and BeeModel is as before.

    zig build -Dzui=true                     # Zui at ../../Zig/beezigui
    zig build -Dzui=true -Dzui-path=/x/zui   # or elsewhere
    ./zig-out/bin/beemodel                   # Edit > Preferences (Ctrl+,)

## How it works

`src/zuiprefs.zig` holds the whole pilot. Zui draws the Preferences dialog
straight into BeeModel's canvas (`ui.cv.px`) with its software renderer, the
same pixels BeeModel hands to the compositor: no copy, no second window.

- **Input.** While the dialog is open, `app.onInput` passes every event to
  Zui first (`zuiprefs.input`): pointer, buttons, wheel, modifiers, keys. Text
  comes from BeeModel's own keyboard layout (`keyboard.char`, dead keys
  included); shortcuts go by the label on the key (`keyboard.shortcutCode`).
  The keymap's Set still captures its key through `keys.captured`.
- **Frames.** Zui runs in BeeModel's draw pass only (`dialogs.drawPrefs`), on
  the canvas's size and scale, so the UI scale preference and the
  compositor's scale apply as everywhere. Zui's timed frames (a tooltip's
  delay, the caret) come through `app.tick`.
- **Look.** A Zui style built from the current theme (`styleFrom`), BeeModel's
  font files (Noto Sans and Noto Sans Bold), 22-unit rows, 14-unit check boxes,
  BeeModel's own half-brightness dim, and the dialog's box, header, sidebar and
  rows at the same places as `dialogs.drawPrefs`.
- **Tests.** Zui's widgets go into `ui.rec` under BeeModel's kinds (`button`,
  `checkbox`, `number`, `text`, `menuitem`, `colour`; `key` and `keyrow` on the
  keymap page), so `--click-label`, `--expect-label`, `--expect-off` and the
  fuzzers find them by the same names.
- **Values.** Everything is still BeeModel's: `prefs.zig`, `prefpages.zig`,
  `keys.zig`, `theme.zig`. Changes are saved at once, as before.

Changed files, each change a compile-time branch on the flag:

| File | Change |
| --- | --- |
| `build.zig` | the `zui` and `zui-path` options; the `zui` and `zui_software` modules when on |
| `src/zuiprefs.zig` | new: the dialog, the input, the look, the record |
| `src/dialogs.zig` | `current()`, `inArea()`; `open` and `drawPrefs` call the pilot |
| `src/app.zig` | `onInput` and `tick` call the pilot |
| `tests/fuzz_prefs.py` | new: random input inside the Preferences (works on both builds) |

## Results

Measured on the pilot's last version.

| Check | Plain build | `-Dzui=true` |
| --- | --- | --- |
| `tests/scenarios.txt` (315 scenarios, 15 of them on the Preferences and keymap) | all pass | all pass |
| `tests/fuzz.py 200` (debug) | | 0 failures |
| `tests/fuzz_prefs.py 300` (debug) | | 0 failures |
| `tests/fuzz_areas.py 100` (debug) | | 0 failures |
| Frame, Preferences open, Interface page (`--bench 300`, release, 1280x800) | 1.88 ms | 1.94 ms |
| Frame, Keymap page | 1.95 ms | 2.16 ms |
| Frame, dialog closed | 0.65 ms | 0.65 ms |

The busiest panels' budget is about 3 ms; the Zui dialog stays within it.
Side by side, the two dialogs differ only in the drop-down arrow, a pixel of
the title's height, and the focused field's fill.

Found and fixed in Zui on the way: a number field ignored a click whose
press and release came in one frame (BeeModel's headless driver does that),
and buttons could not left-align their text. They are why the "Width (px)"
scenario passes and the categories match.

## Not in the pilot yet

- **The Outliner and the Properties.** Next: Zui has the widgets (virtual
  lists with folding, rename and drag to parent; property fields with
  expressions and units), but each is several hundred lines of BeeModel with
  many scenarios, so they come as their own steps.
- **The Preferences in an area of the layout** (`dialogs.areaBody`). An area
  belongs to BeeModel's own layout and docking; it moves when the layout does.
- **A live check.** The pilot ran headless only (the scenarios and fuzzers
  above): open it in a window and try the theme, accent and keymap.

## What BeeModel keeps drawing itself, and why

- **The 3D viewport**: the software rasterizer, the path tracer, grids,
  gizmos, overlays, sculpt and paint cursors. They are the app's content, not
  widgets; Zui gives a canvas and images, the pictures stay BeeModel's.
- **The 2D editors' content** (timeline keys, curves, UVs, render result):
  Zui has 2D views with rulers, handles and selection, the content stays the
  app's.
- **Everything else, for now**: menus, pies and the wheel, the areas and
  their docking, the status bar, toasts, the console, the editors. Zui has
  them all (its phases 16 to 25); moving them over is the rest of the
  migration, one panel at a time behind the same flag.
- **The window** stays BeeModel's own Wayland code. Zui could own it too
  (its native Wayland backend, no libc), but BeeModel already does it, and
  the pilot shows Zui fits inside an app that owns its window.
