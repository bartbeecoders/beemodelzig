# Zui

An immediate-mode UI library in pure Zig, for tools, editors and debug
interfaces. You describe the UI every frame; Zui keeps only small bits of state
such as what is hovered, focused or being dragged.

```zig
ui.beginFrame(.{ .width = width, .height = height, .dt = dt });

ui.labelf("Count: {d}", .{count}, .{});
if (ui.button("Increment", .{}).clicked) count += 1;
_ = ui.slider("Speed", &speed, 0, 10, .{});
_ = ui.textInput("Name", &name_buffer, &name_len, .{ .hint = "Your name" });

const list = try ui.endFrame();
renderer.render(list, .{ .width = width, .height = height });
```

- **Pure Zig core.** The `zui` module needs no libc and no C library. SDL3
  sits in an optional backend; the native backends (Wayland, Win32) need no C
  at all, so a Zui program can be one static binary.
- **Two renderers.** A pure-Zig CPU rasterizer, and an OpenGL 3.3 renderer
  that draws the same pixels about 17 times faster.
- **Your allocator.** All memory comes from the allocator you pass in. A
  stable UI makes no allocations per frame; tests check this.
- **Fast enough to forget about.** About 20 µs per frame for 300 widgets; see
  [Performance](#performance).
- **Sleeps when idle.** The UI asks for frames only when something changes,
  including timed changes such as a caret blink or a tooltip delay.

Widgets: labels, buttons, checkboxes, integer and float sliders, single-line
text input (selection, clipboard, undo), color edit, floating windows (drag,
collapse, close, resize, scroll), popups, tooltips, tree nodes, collapsing
headers, scroll areas and list views, sortable tables, separators and spacers;
and for editors: number fields with expressions, menus and command search,
docking, dialogs and toasts, virtual lists and drag and drop, text views and a
console, a colour picker and themes, pies and a radial wheel, and 2D views.
Add-ons: a node editor and a file browser.
Windows and popups cast soft shadows; text is kerned.
Layout: rows and columns with fixed, fit and grow sizing, padding, alignment.
Keyboard: Tab order with a focus ring, Enter/Space, arrow keys on sliders.
Styling: dark and light themes, and scoped overrides. UI state (window
positions, open nodes, scroll) can be saved and restored, for hot reloading or
for reopening an app the way it was left.

## Quick start

You need [Zig 0.17.1](https://ziglang.org/download/) and, for the window
backend, SDL3:

| System | Install SDL3 |
| --- | --- |
| Arch | `pacman -S sdl3` |
| Debian 13 / Ubuntu 25.04 and later | `apt install libsdl3-dev` |
| Fedora | `dnf install SDL3-devel` |
| macOS | `brew install sdl3` |
| Windows | Not needed: `run.ps1` builds SDL3 from source (see below) |

Or skip installing it: `zig build -Dsdl=source` builds SDL3 from source with
the Zig package manager and links it statically. This also cross-compiles every
demo for Windows from Linux; the `.exe` files need only DLLs that come with
Windows:

    zig build -Dsdl=source -Dtarget=x86_64-windows -Doptimize=ReleaseFast --prefix zig-out/windows

Then, from this folder (on Windows, `.\run.ps1` instead of `./run.sh`):

    ./run.sh demo          # the showcase: every widget, both themes
    ./run.sh demo --gl     # the same, drawn with OpenGL
    ./run.sh list          # all demos, one per development phase
    ./run.sh test          # unit and integration tests
    ./run.sh help          # everything else

`./run.sh` uses [mise](https://mise.jdx.dev) to pick Zig 0.17.1 if you have
it, and plain `zig` otherwise. Each `./run.sh <command>` is a thin wrapper
around a `zig build` step, so `zig build run-demo` works just as well.

## Use it in your project

Add the dependency. From your project folder:

    zig fetch --save <url or path of this repository>

or by hand in `build.zig.zon`:

```zig
.dependencies = .{
    .zui = .{ .path = "../zui" },
},
```

Then import the modules you need in `build.zig`:

```zig
const zui = b.dependency("zui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui", zui.module("zui"));                   // the library
exe.root_module.addImport("zui_software", zui.module("zui_software")); // CPU renderer
exe.root_module.addImport("zui_sdl3", zui.module("zui_sdl3"));         // window, needs SDL3
exe.root_module.addImport("zui_opengl", zui.module("zui_opengl"));     // GPU renderer
exe.root_module.addImport("zui_nodes", zui.module("zui_nodes"));       // node editor add-on
exe.root_module.addImport("zui_files", zui.module("zui_files"));       // file browser add-on
```

[`examples/demo`](examples/demo) is set up exactly this way. Run `zig build run`
inside that folder to see it work as a separate package.

## A complete program

This is the whole loop: a font, a `Ui`, a window, a renderer, and a loop that
sleeps while nothing happens. [`examples/demo/main.zig`](examples/demo/main.zig)
is the same loop with a larger UI.

```zig
const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const sdl3 = @import("zui_sdl3");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var font: zui.Font = try .initDefault(gpa); // embedded Liberation Sans
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    var window = try sdl3.Window.init(.{ .title = "Hello", .width = 640, .height = 400 });
    defer window.deinit();
    ui.clipboard = window.clipboard();
    var renderer: software.SoftwareRenderer = .init(gpa);
    defer renderer.deinit();

    var count: u32 = 0;
    var previous = sdl3.ticksNs();
    var frames_left: u32 = 2;
    while (!window.close_requested) {
        // Sleep until input, or until the UI's next timed change.
        const idle = frames_left == 0 and !ui.redraw_requested;
        const timeout: ?i32 = if (idle) waitMs(ui.redraw_in) else null;
        // After input, draw one extra frame: a widget described early can be
        // changed by one described later in the same frame.
        if (window.pollEvents(&ui.input, timeout)) frames_left = 2;
        if (frames_left > 0) frames_left -= 1;

        const now = sdl3.ticksNs();
        const dt: f32 = @as(f32, @floatFromInt(now - previous)) / 1e9;
        previous = now;
        const size = window.size();
        const w: f32 = @floatFromInt(size.width);
        const h: f32 = @floatFromInt(size.height);

        ui.beginFrame(.{ .width = w, .height = h, .dt = dt });
        ui.labelf("Clicked {d} times", .{count}, .{});
        if (ui.button("Click me", .{}).clicked) count += 1;
        const list = try ui.endFrame();

        try renderer.resize(size.pixel_width, size.pixel_height);
        renderer.clear_color = ui.style.colors.background;
        renderer.renderer().render(list, .{ .width = w, .height = h, .scale = size.scale });
        try window.present(renderer.pixels, renderer.width, renderer.height);
    }
}

/// Milliseconds to wait for input: until `seconds` from now, or forever.
fn waitMs(seconds: ?f32) i32 {
    const s = seconds orelse return -1;
    return @intFromFloat(@min(@ceil(s * 1000), 1_000_000));
}
```

No window at all? [`examples/render_png`](examples/render_png/main.zig) renders a
UI straight to a PNG file, as a static binary with no C library.

## Using the widgets

**Results.** Widgets return an `Interaction`: `clicked`, `hovered`, `held`,
`pressed`, `changed` (a value was edited), `focused`, `submitted` (Enter in a
text field) and the widget's `rect`.

**IDs.** A widget's label is also its ID. Add `##suffix` to tell apart widgets
with the same text (`"Delete##row3"`; only `Delete` is shown). In loops, scope
IDs with `ui.pushIdInt(i)` and `ui.popId()`.

**Errors.** Widgets don't return errors, so there is no `try` on every line.
The first allocation failure is remembered and returned by `ui.endFrame()`.

**Values.** Sliders and number fields are generic: pass a pointer to any integer or float.
`textInput` edits a byte buffer you own, `buffer[0..len.*]`, and stops when it
is full. `colorEdit` edits a `zui.Color`.

**Layout.** Items stack vertically. `ui.beginHorizontal(.{})` /
`ui.endHorizontal()` makes a row, `ui.beginVertical(.{})` a column; both nest.
Sizes are `.auto` (fit the content), `.px(n)` or `.fill` (share the leftover
space). `ui.spacer(.fill)` pushes what follows to the far end, `ui.sameLine()`
puts the next item to the right of the previous one.

**Windows and popups.**

```zig
if (ui.beginWindow("Tools", .{ .open = &show_tools })) {
    defer ui.endWindow();
    // ...
}

const menu = ui.button("Menu", .{});
if (menu.clicked) ui.openPopupAt("menu", menu.rect);
if (ui.beginPopup("menu", .{})) {
    defer ui.endPopup();
    if (ui.button("Quit", .{}).clicked) ui.closeAllPopups();
}
ui.tooltip(menu, "Opens the menu");
```

**Trees, lists and tables.**

```zig
if (ui.treeNode("Assets", .{ .default_open = true })) {
    defer ui.treePop();
    if (ui.selectable("logo.png", chosen == 0, .{}).clicked) chosen = 0;
}

ui.beginScrollArea("list", .{ .height = .px(160) }); // a list view
// ... selectable rows ...
ui.endScrollArea();

const columns = [_]zui.TableColumn{ .{ .name = "Name" }, .{ .name = "Size", .width = .px(80) } };
const table = ui.beginTable("files", &columns, .{});
if (table.header_clicked) |column| sortBy(column);
for (files) |f| {
    ui.tableRow();
    ui.label(f.name, .{});
    ui.tableNextColumn();
    ui.labelf("{d} KB", .{f.kb}, .{});
}
ui.endTable();
```

**Number fields** are what property panels are made of. Drag one sideways
to scrub (Shift: finer, Ctrl: whole steps), click it to type a value or an
expression, Ctrl+wheel or the arrow keys to step:

```zig
_ = ui.numberField("Power", &power, .{ .min = 0, .max = 1000, .suffix = " W", .slider = true });
_ = ui.numberField("Width", &width, .{ .suffix = " m", .evaluator = &.{ .units = &zui.expr.meters } }); // "25cm", "2*pi"
_ = ui.angleField("Cone", &cone_radians, .{});      // shown and typed in degrees
_ = ui.vectorField("Location", &location, .{});     // X Y Z in axis colors
```

Typed text goes through a `zui.Evaluator`: arithmetic, functions, `pi`,
units, and names the app defines through `lookup` (`width/2`); an app with
its own language sets `parse` instead.

**Choices.** `ui.dropdown(name, &index, &items, .{})` with `zui.Choice`
items (label, icon, tooltip, and a reason when one can't be picked),
`ui.dropdownEnum(name, &enum_value, .{})` for an enum, `ui.segmented` for
joined buttons, `ui.iconToggle` for an eye or a lock. Focused, the arrow keys
step through the items.

**Disabled widgets say why.** Everything between `ui.pushDisabled(reason)`
and `ui.popDisabled()` is faded, ignores clicks and keys and leaves the Tab
order; its tooltip shows the reason, and `ui.disabledClick()` returns it when
someone clicks anyway (for a status bar). A null reason disables nothing:

```zig
ui.pushDisabled(if (selection.len == 0) "Select an object first" else null);
defer ui.popDisabled();
```

**Rich tooltips** have a title, a shortcut, a body that wraps, and a warning:
`ui.tooltipRich(result, .{ .title = "Save", .shortcut = "Ctrl+S", .body = "..." })`,
below the widget or `.placement = .beside` it.

**Undo.** Every value widget brackets its edits: `started` when a drag,
typing or a pick begins, `committed` when it ends and is kept, `cancelled`
when Escape undid it. A drag is one commit, however many frames it changed
the value in. A simple undo keeps a copy of the app's state as of the last
commit and, on the next `committed`, pushes that copy as one step:

```zig
const r = ui.numberField("Size", &state.size, .{});
if (r.committed) {
    history.push(last_committed);
    last_committed = state;
}
```

**Context menus.** A right-click sets `context_clicked` on the widget, and
`ui.contextRequest()` names the widget after the frame, so one menu (Reset to
Default, Copy Value, ...) can serve every field. See `15_properties`.

**Menus.**

```zig
ui.beginMenuBar();
if (ui.beginMenu("File")) {
    defer ui.endMenu();
    if (ui.menuItem("Save", .{ .shortcut = "Ctrl+S", .disabled = if (dirty) null else "Nothing to save" })) save();
    if (ui.beginSubmenu("Open Recent", .{})) {
        defer ui.endMenu();
        for (recent) |path| if (ui.menuItem(path, .{})) open(path);
    }
}
ui.endMenuBar();
```

Hovering moves across the bar and into submenus. F10 or Alt+letter opens a
menu; arrows, Enter and Escape (one level at a time) do the rest. Items take
an icon, a check mark, a shortcut, a tooltip and a disabled reason. Menus
taller than the window scroll. `ui.beginContextMenu(result, "name")` opens one
where a widget was right-clicked.

**Command search.** `ui.commandPalette("palette", &open, &commands, .{})`
shows a search box over `zui.PaletteCommand`s (label, category, shortcut,
disabled reason) while `open` is true, ranks them by a fuzzy match with the
matched letters marked, and returns the one picked: BeeModel's F3.

**Shortcuts.** `zui.Shortcut` is a key with modifiers: `Shortcut.parse("ctrl+shift+z")`,
`s.format(&buffer)` gives "Ctrl+Shift+Z", `s.pressed(&ui.input)` checks it.
`ui.shortcutField("Save", &maybe_shortcut, .{})` lets people set one by
pressing it (Backspace clears, Escape keeps the old one).

**Areas and docking.** A `zui.Dock` is a layout of areas, each showing one
of your editors: plain data you keep (one per workspace) and can save with
`dock.write` / `zui.Dock.read`.

```zig
var dock: zui.Dock = .init(viewport);
_ = dock.split(dock.root, .right, outliner);

ui.beginDockSpace("dock", &dock, .{ .editors = &editor_choices });
var ids: [zui.Dock.max_areas]zui.AreaId = undefined;
for (dock.areas(&ids)) |id| {
    const area = ui.beginArea(id) orelse continue;
    defer ui.endArea();
    // header widgets for this editor, then:
    ui.areaBody();
    drawEditor(area.editor);
}
const changes = ui.endDockSpace(); // .created, .closed, .changed
```

People drag splitters; drag a header onto another area (an edge splits
there, the middle swaps, a tint shows which); drag an area's top-left
corner into its neighbour to join them; split, maximize (Ctrl+Space) and
close from the header; right-click a header to float the area as a panel,
and drop a panel on one of the five guides to dock it. F6 cycles the active
area, and Tab stays inside it.

**Tabs.** `ui.tabBar(name, &index, &tabs, .{ .addable, .renamable, .closable })`
for workspaces (double-click or F2 renames, the result says what to add,
close or rename), or `.vertical = true` for a column of icon tabs.

**Dialogs.** A modal dialog dims the window and takes the pointer, the keys
and Tab until it closes:

```zig
if (ui.beginDialog("Save changes?", &asking, .{})) {
    defer ui.endDialog();
    ui.label("The scene has changes that aren't saved.", .{});
    if (ui.dialogButtons(&.{ "Save", "Don't Save", "Cancel" }, .{ .default = 0, .cancel = 2 })) |i| {
        asking = false;
        if (i == 0) save();
    }
}
```

Enter presses the default button (or the focused one), Escape the cancel
button. `ui.dialogOpen()` tells the app to leave its shortcuts alone.

**Status and feedback.** `ui.beginStatusBar()` / `endStatusBar()` make a row
for `ui.keyHint("G", "Move")` chips and `ui.jobChip("Rendering", 0.48, 4.2, .{ .action = "Stop" })`,
which shows the percentage, the time taken and, once it can tell, the time
left. `ui.progressBar(fraction, .{})` glides when the fraction is null.
`ui.toast("Saved", .success, .{})` shows a message for a few seconds; a click
on it is `ui.clickedToast()` and never reaches what is under it. An idle
UI sleeps until the next toast is due to go. `ui.card(title, .{ .icon, .image, .subtitle })`
is a large button for welcome screens.

**Long lists and trees.** Only the rows in view are described, so a list of
thousands costs what a screenful does. `selected` is one bool per row,
kept up to date by clicks (Ctrl adds or removes, Shift selects a range) and
keys (arrows, Shift+arrows, Home/End, Page Up/Down, Ctrl+A):

```zig
var list = ui.beginList("outliner", selected, &list_state, .{});
for (list.first..list.end) |i| {
    ui.beginRow(&list, i, .{ .label = names[i], .depth = depth[i], .fold = open[i], .renamable = true });
    _ = ui.iconToggle(eye_names[i], &visible[i], .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off } });
    const row = ui.endRow(&list);
    if (row.fold_clicked) open[i] = !open[i].?;
    if (row.renamed) |name| rename(i, name); // double-click or F2
}
const result = ui.endList(&list); // .delete, .activated, .empty (below the rows)
```

`ui.beginTiles` / `ui.tile` / `ui.endTiles` do the same for a grid of
thumbnails. Scroll areas with `.horizontal = true` also scroll sideways
(Shift+wheel).

**Drag and drop.** `ui.dragSource(row.interaction, .{ .kind = "object", .data = i, .label = name })`
after a widget makes it draggable; `ui.dropZone(rect, "object")` returns
the drag while it is over a target, which lights up. Say what letting go
does with `ui.dropHint("Child of Cube")`, or `ui.refuseDrop(reason)`; act
when the drop says `released`. Escape cancels. Files dropped from the
system arrive through `ui.fileDrop(rect)` (the SDL backend feeds them in).

**Text.** `ui.wrappedText(text, .{})` wraps between words to the width it
gets; `ui.richText(&spans, .{})` mixes colors and key chips
(`.{ .text = "Ctrl+S", .key = true }`). `zui.LogBuffer` holds lines in fixed
memory, dropping the oldest, and `ui.textView("log", &log, &state, .{ .font = &mono })`
shows any number of them (only those in view are drawn): it follows new lines
while at the bottom, selects by dragging across lines, takes a whole
message on a double-click, and copies with Ctrl+C.
`ui.consoleInput(name, &buffer, &len, &history, .{ .complete = ... })` is a
command line with Up / Down history and Tab completion that keeps focus after
Enter. `ui.textArea(name, &buffer, &len, .{ .enter_sends = true })` edits
several lines that wrap; Shift+Enter starts a new line, Ctrl+Z undoes (a word
of typing at a time) and Ctrl+Shift+Z or Ctrl+Y redoes. To let it grow with
its text, pass `.height = .px(ui.textAreaHeight(text, width, 1, max_lines))`.
A text view's lines can be the app's own wrapping of longer text: mark the
continuations `.soft` and copying joins them without a line break.

**Saving UI state.** `ui.saveState(allocator)` returns the window positions,
sizes, collapse and scroll, open tree nodes and headers, and scroll areas as
bytes; `ui.restoreState(bytes)` puts them back into a new `Ui`. A damaged or
truncated buffer is rejected without changing anything. The `12_hot_reload`
example uses this to swap in rebuilt UI code while the program runs.

**Styling.** Assign `ui.style = .light` (or `.dark`, or your own `zui.Style`)
to switch themes. Override part of the UI with `ui.pushColor(.button, color)`,
`ui.pushMetric(.rounding, 0)` or `ui.pushStyle(theme)`, and undo with
`ui.popStyle()`. Overrides never leak past their pop. The `09_style` demo edits
a theme live and copies it as Zig code.

**Keyboard.** Tab and Shift+Tab move focus; Enter and Space press buttons and
toggle checkboxes; arrow keys, Page Up/Down and Home/End move sliders; Escape
lets go, undoes a text edit, or closes a popup. `ui.wantsKeyboard()` tells your
app when to leave keys alone.

**Custom widgets** use the same calls as the built-in ones: `ui.place` or
`ui.placeSized` for space, `ui.interact` for the mouse, `ui.focusable` for
keyboard focus, and `ui.drawRect` / `ui.drawText` or a painter to draw. See
[`src/widgets.zig`](src/widgets.zig).

**Drawing your own.** `ui.painter()` draws into the current window, popup or
canvas: lines (horizontal and vertical ones stay sharp), dashed lines,
polylines, convex polygons, circles, arcs, pie slices, ring segments, Bézier
curves, gradients, colored triangles, images and icons. Edges are
anti-aliased. A canvas is an area you paint yourself, with its own mouse
handling; a viewport, a timeline or a node graph starts as one:

```zig
const c = ui.beginCanvas("view", .{ .height = .fill, .cursor = .crosshair });
defer ui.endCanvas();
if (c.dragging == .middle) pan = pan.add(c.delta); // middle-drag pans
if (c.wheel.y != 0) zoom *= std.math.pow(f32, 1.1, c.wheel.y);
c.painter.bezier(a, a.add(.{ .x = 80 }), b.sub(.{ .x = 80 }), b, color, 2);
c.painter.image(&viewport_image, c.rect, .{ .filter = .nearest });
```

The canvas keeps the right or middle button while it is held, even when the
pointer leaves it, and takes the wheel while hovered. `.rect` puts it at a
place of your own instead of the layout's. A stroke that must see every
sample (sculpting, painting, a pen's pressure) reads
`ui.input.pointerEvents()`: the frame's moves, presses, releases and wheel
turns in the order they came, each with its position, modifiers and pressure
(`input.onPressure` for a pen).

**Images** are pixels you own: `zui.Image.initArgb(pixels, w, h)` for
`0xAARRGGBB` pixels, `initAlpha` for a coverage mask drawn in a tint color.
Keep them alive until the frame is rendered, and call `image.touch()` after
changing them so the OpenGL renderer uploads them again.

**Icons.** Buttons and list rows take an `.icon`. Zui has a small built-in set
drawn from strokes (`.{ .builtin = .close }`, `.search`, `.chevron_down`,
`.warning` and more), sharp at any scale. Bring your own as an atlas:
`zui.IconSet.grid(&atlas_image, 16, 16).icon(3)`. Bitmap icons are drawn pixel
for pixel at whole multiples of their size (100 %, 200 %) and smoothed between;
set `whole_pixels` on the set to keep pixel art at a whole multiple always
(a 16-pixel icon in an 18-unit button stays 16, centred, and sharp).
`ui.icon(icon, .{})` puts one in the layout; `"##close"` with an icon makes a
square icon-only button.

**Pointer shapes.** Widgets ask for a cursor in `ui.cursor` (the I-beam over
text fields, diagonal arrows over a resize grip); set it yourself while the
pointer is over something of yours. Pass it to the backend after the frame:
`window.setCursor(ui.cursor)`.

**Colours.** `ui.colorEdit(name, &color, .{})` shows a swatch that opens the
picker; `ui.colorPicker(name, &color, .{})` puts the picker anywhere. It has a
saturation and value square, a hue strip and an alpha strip, the old colour
beside the new one (click the old one to go back), a hex field, R G B or
H S V fields, the app's `.swatches`, `.recent` colours (a `zui.RecentColors`
you keep; each commit adds to it) and an eyedropper. Right-click a swatch to
copy or paste its hex code, or reset it to `.default`. A drag in the square is
one undo step; Escape puts the colour back. `.compact = true` makes a narrow
label-and-swatch field, for nodes. `zui.color` has the maths: `toHsv`,
`fromHsv`, `mix`, `contrast` (WCAG) and `textOn` (black or white).

The eyedropper needs one pixel read back: while it is out, `ui.sample_request`
says where, and after rendering the backend passes that pixel to
`ui.input.onColorSample` (both renderers have `pixelAt`; the demo harness does
this). The click that takes the colour reaches no widget; Escape cancels.

**Themes.** `zui.theme.build(.{ .background = ..., .text = ..., .accent = ... })`
derives a whole style from three colours, keeping every text colour at least
4.5:1 against the surfaces it sits on and marks such as the focus ring at 3:1;
text on the accent is black or white. `.colorblind_axes = true` uses axis
colours told apart with red-green colour blindness. `zui.theme.presets` has
nine themes, and `zui.theme.contrastProblems(style, &buffer)` checks any
style (a test runs it over every preset). `ui.themePreview(name, &style, .{})`
draws a miniature of a theme for a theme list.

**UI scale.** `ui.setScale(1.5)` zooms the whole UI from 75 to 200 %, on top of
the display's own scale, from the next frame. Keep passing the window's size
to `beginFrame`; render with `ui.renderFrame(display_scale)`, which tells the
renderer the combined scale, so text is rasterized at the new size rather than
stretched. Pointer positions are converted for you; scripts and the widget
record stay in UI units.

**Pies and the wheel.** Menus around the pointer. A pie has up to eight
choices by direction (left, right, down, up, then the diagonals): hold its
key, flick towards a choice and let go, or tap the key and click. A quick tap
without moving reports `.tapped`, so the key can still do its own job:

```zig
if (z_pressed_over_viewport) ui.openPie("Shading", .z);
switch (ui.pie("Shading", &shading_items, .{ .title = "Shading" })) {
    .chosen => |i| shading = i,
    .tapped => xray = !xray,
    .none, .cancelled => {},
}
```

The wheel is a ring of coloured entries with icons; an entry with
`.children` opens an outer arc. Click, or press, drag and let go; 1 to 9, 0
and - pick by number; Backspace goes back to the ring; Esc or a click in the
middle closes. Greyed entries say why above the wheel. Open it with
`ui.openWheel("Context", .right)` on a right press, and read
`ui.wheel("Context", &entries, .{})` (`.chosen` has the entry and the arc
entry). While either is open it takes every press and key.

**2D views.** A timeline, a graph editor or an image viewer starts as a 2D
view. The app keeps a `zui.View2D` (origin and zoom per axis):

```zig
const v = ui.beginView2D("graph", &view, .{ .rulers = .{ .x = .frames, .y = .values }, .y_up = true, .content = bounds });
_ = ui.frameRange(v, &start, &end);
for (keys, 0..) |*k, i| {
    const h = ui.viewHandle(v, i, &k.pos, .{ .selected = k.selected, .snap = .{ .x = 1, .y = 0 } });
    if (h.interaction.pressed) select(i, ui.input.modifiers.shift);
    moveOtherSelected(h.delta); // all selected keys move together
}
_ = ui.playhead(v, &frame, .{});
if (ui.endView2D().box) |box| selectInside(box.rect, box.mode);
```

The wheel zooms about the pointer (`.zoom_axes = .x` for a timeline), Ctrl and
Shift with the wheel pan, the middle button drags, Home fits `.content`. Zoom
and pan have limits. Rulers label frames or values at steps of 1, 2 or 5; the
playhead scrubs on the top ruler. Handles keep their size at every zoom,
snap (Ctrl turns snapping off), and Escape puts them back. A drag on empty
space draws a selection box (Shift adds, Ctrl removes). `toScreen`, `toWorld`
and `rectToScreen` convert for your own drawing. `ui.imageView(name, &image,
&view, .{})` is a ready-made image viewer, zooming up to 32 times with sharp
pixels and a minimap; `ui.beginMinimap` / `ui.endMinimap` add one to any view.

**Fonts.** `zui.Font.initDefault` is Liberation Sans, `initMono` Liberation
Mono, and `zui.Font.loadFile(gpa, io, path)` loads any TrueType file, such as
the system's Noto Sans. `ui.pushFont(&mono)` / `ui.popFont()` switch fonts for
part of the UI. Set `font.fallback = &other` to take characters a font lacks
(symbols, CJK) from another one.

## Add-ons

Two bigger pieces are separate modules built only on Zui's public API.

**Node editor (`zui_nodes`).** The graph stays yours: describe frames, nodes,
pins and links each frame, and apply the edits the editor returns.

```zig
var g = nodes.begin(ui, "material", &editor, .{});
for (graph.nodes) |*n| {
    var node = g.beginNode(n.id, n.pos, .{ .title = n.name, .color = n.color, .selected = n.selected });
    g.output(&node, n.out_pin, "BSDF", .{ .color = shader_color });
    if (g.beginInput(&node, n.rough_pin, "Roughness", .{ .value = true }))
        _ = ui.numberField("Roughness", &n.roughness, .{ .width = .fill, .slider = true });
    g.endInput(&node);
    g.endNode(&node);
}
for (graph.links) |l| g.link(l.id, l.from, l.to);
for (g.end()) |edit| apply(edit); // move, select, link, unlink, add, delete, ...
```

Drag from a pin to link, or drop the wire in empty space to be asked what to
add there; drag a linked input to take its link off. Wires are coloured by
the pin type. Double-click a wire for a reroute knot; Alt+click cuts a wire
and Alt+drag cuts every wire it crosses. Click or box-select nodes; moving
one selected node moves them all. Comment frames move with their nodes,
resize from the corner and rename on a double-click. `g.alignSelected` and
`g.distributeSelected` line nodes up. X deletes, Shift+D duplicates, Ctrl+C /
Ctrl+V copy and paste, Shift+A asks for the add menu (`nodes.addMenu`:
categories in columns, with search), and `nodes.paletteItem` entries drag
onto the canvas. Zoom runs from 25 to 200 % with sharp text, with a minimap.

**File browser (`zui_files`).** An open and save browser to put in a dialog:

```zig
var disk: files.DiskSource = .{ .io = io };
var browser: files.Browser = try .init(gpa, disk.source(), home);
switch (files.fileBrowser(ui, "open", &browser, .{ .mode = .open, .kinds = &.{scenes, images} })) {
    .chosen => |paths| openAll(paths),
    .cancelled => closeDialog(),
    .none => {},
}
```

It lists name, size and date (click a column to sort, folders first), with a
name filter, the kinds asked for or all files, and hidden files on Ctrl+H.
Crumbs, back, forward and up (Alt+Left, Alt+Right, Backspace); Ctrl+L types a
path with Tab completion. The sidebar shows the app's places, favourites,
drives with their free space (`files.freeSpace`) and recent folders. The
preview shows PNG images and the app's own thumbnails; the app can add an
options panel (export settings). Saving over a file asks first, and a typed
name gets the kind's extension. It reads through a `files.Source`, so tests
can use a fake file tree.

## Testing and scripting

**The widget record.** With `ui.recording = true`, every frame keeps a list
of the widgets it showed: kind, label, value as text, visible rect, enabled,
focused, hovered, tooltip and the window it is in. Hidden widgets (scrolled
away, in a collapsed window, in a popup still sizing itself) are left out.
Read it after `endFrame`:

```zig
ui.recording = true;
// ... a frame ...
for (ui.widgets()) |w| std.debug.print("{s}:{s} = {?s}\n", .{ @tagName(w.kind), w.label, w.value });
const snap = ui.findWidget("Settings > checkbox:Snap");
try ui.writeWidgets(writer, .json); // or .text
```

Widgets are named `label`, `kind:label` (`button:Save`, `slider:Volume`) or
`Window > kind:label`; a widget with no visible text goes by its ID, so
`"##notes"` is `notes`. Custom widgets join with `ui.recordWidget`. With
recording off this costs nothing, and `ui.hoveredWidget()` still says which
widget is under the pointer, for app keys that act on it (copy a field's
value, insert a keyframe).

**Scripts** drive a `Ui` by name, without a window:

```
click button:Menu
click menu > button:Delete
drag slider:Volume to 75%
drag color_area:Saturation and value to 80% 10%
type hello world
hold z
release z
key ctrl+a
hover button:Save
wait 0.8
expect tooltip:Write the file exists
expect checkbox:Snap = true
shot after.png
```

`zui.ScriptPlayer` turns each line into input and frames; the
[script docs](src/script.zig) list every command. It waits up to a second for
a widget that isn't there yet (a popup opening), refuses to click one covered
by a window, and on failure `player.message()` names the line and the reason.
The phase demos take `--script FILE` and `--dump-ui [json|text]`, and
`zig build scenarios` plays the scripts in `tests/scenarios` against them.

## Writing a backend

A backend has two jobs: feed input into `ui.input` before a frame, and draw the
`DrawList` that `ui.endFrame()` returns. The two halves are independent;
`zui_sdl3` does input and presentation, `zui_software` does the drawing.

**Input.** Call these on `ui.input` as events arrive, in logical units:

| Method | When |
| --- | --- |
| `onMouseMove(pos)` | The pointer moved. |
| `onMouseButton(button, down)` | A button went down or up. `onMouseButtonClicks` also passes the click count, for double and triple clicks. |
| `onScroll(delta)` | The wheel moved, in lines; positive `y` scrolls up. |
| `modifiers = .{ ... }` then `onKeyPress(key)` | A key went down or repeated. Map only the keys in `zui.Key`. |
| `onText(utf8)` | Text was typed, after keyboard layout and input methods. |
| `onKeyRelease(key)` | A key went up (pies close on it). |
| `onFileDrop(path, pos)` | A file was dropped on the window. |
| `onColorSample(color)` | The pixel at `ui.sample_request`, read back after rendering (the eyedropper). |
| `viewport`, `keyboard_viewport` | Which OS window the pointer and the keyboard are in, for detached windows. |

Set `ui.clipboard` to a `zui.Clipboard` for the system clipboard; without one,
copy and paste work only inside the `Ui`.

**Drawing.** A `zui.Renderer` is a vtable with five functions: `begin(frame)`,
`drawRect(cmd)`, `drawText(cmd)`, `setClip(rect or null)` and `end()`, plus
optional ones a backend can leave out (those commands are then skipped):
`drawShadow`, `drawPath`, `drawMesh` and `drawImage`. Paths are lines and
convex polygons; `zui.tessellate.Tessellator` turns one into triangles with a
one-pixel fading fringe for anti-aliasing, so a backend only needs to fill
triangles with colors blended across them. Meshes are such triangles already.
Images carry an `id` and a `version` for caching on the GPU.
`renderer.render(list, frame)` replays the list through them in order. A rect has
a fill, an optional border drawn inside it, and a corner radius. Text is a run of
UTF-8 with a font, a size, and a baseline position. Coordinates are logical;
`frame.scale` says how many pixels make a logical unit.

To draw text, a backend asks the `zui.Font` from the command for glyph bitmaps
(`font.glyph(codepoint, size, subpixel)`), which are cached, and blends them.
[`backends/software.zig`](backends/software.zig) is a complete reference:
rounded rects with anti-aliasing, shadows, paths, triangles, images, clipping,
HiDPI and text. [`backends/opengl.zig`](backends/opengl.zig) does the same on the GPU: one
shader with the same distance math, a glyph atlas, and batched draws. It needs
only a function that looks up GL entry points, so it works with any window
library that gives you a GL 3.3 context:

```zig
var window = try sdl3.Window.init(.{ .graphics = .opengl });
var gl = try opengl.GlRenderer.init(gpa, sdl3.glGetProcAddress);
// each frame:
gl.renderer().render(list, frame);
try window.swap();
```

`zig build gl-check` renders the same UI with both renderers and compares the
pixels; today no pixel differs by more than 3 out of 255.

**Cursor.** After `endFrame`, `ui.cursor` is the pointer shape to show.

**Timing.** After `endFrame`, `ui.redraw_requested` means "draw another frame
right away" (layout is settling) and `ui.redraw_in` means "draw one within this
many seconds" (caret blink, tooltip delay). Otherwise sleep until input.

## Native backends, no C

`./run.sh native` runs a demo on the system's own window protocol, with no C
library at all: the Wayland backend on Linux (a static binary: no libc, no
libwayland, no libxkbcommon), the Win32 backend on Windows (no C runtime, the
system DLLs only).

```zig
var display: wayland.Display = undefined; // zui_wayland
try display.init(gpa, init.environ_map, .{ .title = "My tool", .app_id = "my-tool" });
defer display.deinit();
ui.clipboard = display.clipboard();
while (!display.close_requested) {
    _ = try display.wait(&ui.input, if (ui.redraw_requested) 0 else -1);
    const size = display.size();
    ui.beginFrame(.{ .width = size.width, .height = size.height, .dt = dt });
    display.act(ui.clientFrame("My tool", .{ .maximized = display.maximized() }));
    // ... the UI ...
    try display.present(&ui, try ui.endFrame());
}
```

**Wayland** (`backends/wayland.zig`) speaks the wire protocol over the
compositor's socket with raw syscalls: xdg-shell windows; shm buffers the
software renderer draws into directly; fractional scale with viewporter;
cursor shapes; the clipboard and dropped files through the data device; the
keyboard layout from the compositor's XKB keymap (dead keys, AltGr, Caps Lock;
shortcuts by the label on the key, so Ctrl+Z is the key labelled Z on AZERTY);
key repeat; and an OS window for each detached UI window. It sleeps until
something happens and draws only when the compositor is ready.

**Win32** (`backends/win32.zig`) declares what it needs from user32, gdi32,
kernel32 and shell32 itself: a per-monitor DPI-aware window, the software
renderer's pixels shown with `SetDIBitsToDevice`, mouse, wheel and keys, text
from `WM_CHAR` (surrogate pairs included), cursors, the clipboard and dropped
files. The window frame is the system's.

**A window frame drawn by Zui.** Wayland leaves the frame to the app.
`ui.clientFrame(title, .{ .maximized = ... })`, first in the frame, draws a
title bar with minimize, maximize and close, moves the rest of the UI below
it, and returns what was asked: `.move`, `.resize` (which edges), `.minimize`,
`.maximize` (also on a double click), `.close`. The backend asks the system
to do it (`display.act`), since moving a window needs the press that started
it.

**Windows in OS windows of their own.** `beginWindow(title, .{ .detached = true })`
shows a window in an OS window of its own: a panel on another monitor. After
`endFrame`, `ui.viewports()` lists them with their size and draw list (the
window, its popups, and tooltips while the pointer is there); the backend
opens and closes OS windows to match, reports sizes with `setViewportSize`
and closes with `closeViewport`, and sets `input.viewport` (pointer) and
`input.keyboard_viewport` (keyboard) to say which OS window an event came
from. Positions are in that window's own units. Tab stays in the OS window
that has the keyboard. Dragging a detached window's title bar or grip asks
the system to move or resize it. Set `.detached = false` to bring it back.

## Embedding Zui in an app that owns its window

An app with its own window, event loop and framebuffer (a game, BeeModel)
keeps them all: it passes its events to `ui.input` and lets the software
renderer draw over its own pixels, in place.

```zig
sw.useBuffer(framebuffer, pixel_width, pixel_height); // the app's pixels
sw.clear = false;                                     // keep what it drew
// each frame, after drawing the app's own content:
ui.beginFrame(.{ .width = units_w, .height = units_h, .dt = dt });
describeUi(&ui);
sw.renderer().render(try ui.endFrame(), ui.renderFrame(display_scale));
```

[`examples/embed`](examples/embed/main.zig) does this without a window
(`./run.sh embed out.png`). While `ui.wantsKeyboard()` is true, keep keys
for the UI; while the pointer is over a Zui window or widget, keep the
pointer for it too.

**BeeModel.** BeeModel (`../Beemodel`) is moving onto Zui this way, inside its
own Wayland window, from its own events, theme and fonts: its Preferences,
dialogs, forms and prompts are Zui's, and so are panels inside its own layout
(the Preferences in an area, the redo panel). A panel's commands are drawn
when BeeModel draws the area under it (`ui.rootCommandCount`, `ui.rootView`),
so BeeModel's own menus still go over it; the rest of the frame (windows,
popups, tooltips) is drawn last. Its `Docs/beezigui-migration.html` has the plan
and where it stands.

## Performance

`zig build bench` runs a headless frame with about 300 widgets across the root,
two windows and a popup, 1000 times, in ReleaseFast. On a desktop CPU:

| Pass | Mean time per frame |
| --- | --- |
| UI: describe the frame and `endFrame` | about 31 µs |
| Software render, 1280×800 | about 2.3 ms |
| Allocations during the 1000 frames | 0 |

The UI pass is negligible; the renderer dominates, mostly filling large
rectangles. `zig build gl-check -Doptimize=ReleaseFast` times both renderers on
one frame at 900×620 that includes a panel of shapes and images and an open
radial wheel: about 1.8 ms in software and 0.23 ms with OpenGL. An idle window
uses no CPU with either.

`zig build bench -- 500 1280 800 nodes` measures a node graph instead: 200
nodes with a field each and 300 wires, all in view, take about 0.4 ms for the
UI pass and 9.6 ms to render in software, with no allocations.

## Known limits

- **Platforms.** Tested on Linux (Wayland and X11). Every demo builds for
  Windows, and `./run.sh cross` compiles the core, both renderers and a
  headless program for macOS, but nothing has been run on Windows or macOS
  yet, and `run.ps1` is untested.
- **SDL3 from source** (`-Dsdl=source`) uses the
  [castholm/SDL](https://github.com/castholm/SDL) package (SDL 3.4.20, linked
  statically). Verified on Linux; the first build takes about 30 seconds.
  Cross-compiling it for macOS needs Apple's SDK.
- **Hot reload** reloads app UI code; changes to Zui itself or to the shared
  state type need a restart. Tried on Linux only.
- **Text** has no shaping or right-to-left support, and no input-method
  preview (composed text arrives when committed). Labels don't wrap. Characters
  missing from the font and its fallbacks show as an empty box; there is no
  kerning between a character and one from a fallback font.
- **Shapes.** Filled paths must be convex; draw concave shapes as a mesh.
  Meshes have no anti-aliasing. Lines have square ends and mitered corners
  (very sharp corners are cut short), no round caps or joins.
- **Text areas** keep their caret, scroll and undo history for one focused
  area at a time: the history goes when another area takes the focus.
- **Windows** can't be moved or resized from the keyboard.
- **Native backends.** The Wayland backend was tried on Hyprland (typing in
  two layouts, the clipboard both ways, a detached panel); dragging the frame
  and dropping files were not tried by hand. It needs a compositor with
  `wp_cursor_shape_v1` for pointer shapes and with fractional scale and
  viewporter for scales other than 1. There is no input-method support.
  The Win32 backend is compile- and link-checked only. Detached windows have
  OS windows only on the Wayland backend. There is no native macOS backend.
- **Pies and the wheel** keep their centre on screen, so near an edge the
  pointer isn't at the centre.
- **2D views** don't nest; the minimap assumes y grows downwards.
- **Node editor:** a widget inside a node that another node overlaps can
  still take a press (the nodes themselves pick the topmost).
- **File browser:** POSIX paths only (Windows drive letters come with native
  platform work); previews read 8-bit, non-interlaced PNG, other formats need
  the app's thumbnails; free space is shown on Linux only.
- **HiDPI** scaling is unit-tested, but has not been tried on a real HiDPI screen.
- **OpenGL renderer** needs OpenGL 3.3. There is no Vulkan, Metal or
  Direct3D renderer.

[PLAN.html](PLAN.html) tracks what is done and what comes next.
[Docs/improvements.html](Docs/improvements.html) lists the bugs, performance work and API
gaps found so far, most with a reproduction in `Docs/repro/` (`Docs/repro/run.sh`).

## Project layout

| Path | What it is | Dependencies |
| --- | --- | --- |
| `src/` | The `zui` module: `Ui`, widgets, layout, style, fonts, icons, draw commands and tessellation | none |
| `backends/software.zig` | CPU rasterizer that draws into a pixel buffer, plus a PNG writer | `zui` |
| `backends/sdl3.zig` | Window, input, clipboard, presentation and GL contexts | `zui`, SDL3 |
| `backends/opengl.zig` | OpenGL 3.3 renderer, functions loaded at runtime | `zui` |
| `backends/wayland.zig` | Native Wayland window, input, clipboard, drops, XKB layouts; no libc | `zui`, software |
| `backends/win32.zig` | Native Win32 window and input; no C runtime | `zui`, software |
| `examples/demo` | The showcase; also builds as a separate package | all of the above |
| `examples/render_png` | A UI rendered to a file, no window | `zui`, software |
| `examples/embed` | Zui drawn over an app's own framebuffer, from its own events | `zui`, software |
| `examples/native` | The native backend demo (`./run.sh native`) | `zui`, a native backend |
| `addons/nodes.zig` | The node editor (`zui_nodes`), public API only | `zui` |
| `addons/files.zig` | The file browser (`zui_files`), public API only | `zui` |
| `examples/01_*` … `25_*` | One demo per development phase; all accept `--gl` | all of the above |
| `examples/12_hot_reload` | Host program plus a UI library rebuilt while it runs | all of the above |
| `tests/` | Tests that drive `Ui` with simulated input and scripts | `zui`, software |
| `tests/scenarios/` | Scripts played against the phase demos (`zig build scenarios`) | the demos |
| `bench/` | Frame-time benchmark | `zui`, software |
| `tools/check_docs.zig` | Fails if a public declaration has no doc comment (`zig build check-docs`) | none |
| `tools/gl_check.zig` | Compares OpenGL and software output pixel by pixel (`zig build gl-check`) | all of the above |

## License

MIT, see [LICENSE](LICENSE). The bundled Liberation Sans font is under the SIL
Open Font License, see `src/fonts/LICENSE-LiberationSans.txt`.
