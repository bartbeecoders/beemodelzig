# BeeModel

A 3D modeling tool in **Zig 0.17**:

- **No libc, no libwayland, no toolkit.** A static ELF that talks to the kernel through
  `std.os.linux` syscalls and to the compositor through the Wayland wire protocol
  (`src/wayland.zig`), XKB keymaps included (`src/keyboard.zig`, no libxkbcommon).
- **Every pixel in software**: its own TrueType engine (`src/ttf.zig`, Noto Sans from the
  system), 114 icons, a depth-buffered rasterizer for the 3D view and a path tracer; the
  UI drawn by BeeZigUi (`../BeeZigUi`), an immediate-mode UI library in pure Zig.
- **Commands**: `src/catalog.zig` holds all 692 operators with their ids, labels,
  shortcuts and docs, the menus, the nine themes and the icons. Commands that aren't
  implemented yet stay visible, greyed, with "Not available yet".
- **Files**: `.bee` scenes open and save (`src/bee.zig`); OpenUSD, glTF, STEP and more.

BeeModel began as a port of an earlier BeeModel written in x86-64 assembly. Since
2026-11-14 it is developed on its own; the files once generated from the assembly
sources are ordinary source now (`tools/legacy/README.md`), and some tests still
mention the original they used to compare with.

```
./run.sh                  # build (ReleaseFast) and open the window
./run.sh debug            # build with safety checks, then run
./run.sh --shot out.ppm   # headless: scripted input, one frame to a PPM
```

Zig comes from `PATH` if it is 0.17.x, otherwise from mise (`mise.toml` pins 0.17.1).

## Plans and history

- [Docs/beezigui-migration.html](Docs/beezigui-migration.html): moving the whole UI onto
  BeeZigUi, milestone by milestone.
- [Docs/features.html](Docs/features.html): the features of the assembly BeeModel and how
  far the port had come when porting stopped (2026-11-14). Kept as history.

## What works (so far)

| Area | Details |
|------|---------|
| Window | xdg-shell, client-side title bar, edge resize, cursor shapes, frame callbacks, key repeat, XKB layouts (AltGr, dead keys, UTF-8), layout-aware shortcuts |
| Commands | Menus, submenus, keyboard menus (F10, Alt+letter), F3 palette, F1 shortcut list, tooltips with "Not now: why", greyed reasons |
| Areas | Split, join (corner drag), resize, maximize, close, dock / swap by header drag, floating panels with five dock guides, F6 active area, six workspaces + your own |
| Viewport | Orbit / pan / zoom, gizmo with zoom / pan / ortho / camera buttons, Numpad views (glide), orthographic, camera view, header (mode, shading, grid, snap, pivot, overlays), Z / Ctrl+Tab / Shift+S pies, right-click wheel, 3D cursor on surfaces |
| Editing | Multi-selection, G / R / S with axis lock, snapping, typed values, pivots and orientations, parenting (Ctrl+P / Alt+P, outliner drag), hide / reveal, undo / redo with history |
| Editors | Tools, Outliner (tree, lock / render / eye, filter, rename), Properties (icon tabs: Object incl. lights and cameras, Material, Scene, Viewport), Console (commands, operator ids, history), Timeline |
| Rendering | Material Preview, the Hive path tracer on every core, F12 into a Render area, denoiser, passes saved as PNG, Rendered shading (live path tracing in the viewport, on the CPU: Preferences > Viewport > Rendered samples, denoise) |
| Look | TrueType UI, icons, nine themes + accent, colour picker, Preferences (saved to `~/.config/beemodel-zig/prefs`) |
| Animation | Keyframes, actions, layers, Timeline, Dope Sheet, Graph Editor, drivers, onion skins, render to video; undo keeps user edits apart from evaluated values |
| Rigging | Armatures, edit bones, pose, FABRIK and CCD IK, auto weights, Armature modifier (linear and dual quaternion), constraints, bone paths, Rig tab |
| Sculpting | 11 brushes, symmetry, falloff, tablet pressure, stabilizer, dynamic topology, Multires |
| Painting | Texture, vertex and weight paint, 16 paint layers, painting in the UV Editor |
| UV | Seams, LSCM unwrap, smart project, pack, the UV Editor with heat maps; baking normal, AO and curvature maps |
| Modifiers | Mirror, Array, Solidify, Subsurf, Bevel, Decimate, Remesh, Boolean: 8 a stack, non-destructive, saved in `.bee`; Edit > Boolean |
| CAD | Units and parameters, measure, print check, sketches with a constraint solver, the feature tree, a NURBS B-rep kernel (booleans, fillets, chamfers), STEP import / export, 3MF / PDF / DXF / SVG, SDF, mechanisms (joints, gears, racks, limits, collisions, mates), the CAD tab |
| Physics | Rigid bodies (shapes, constraints, collisions, a cache and bake), force fields, cloth and soft bodies, shatter (shards, bricks, balls, glue), particles and liquid, play mode (F5) with logic graphs, the Physics and Particles tabs |
| Nodes and content | The Node Editor (shader, geometry-node and logic graphs), 42 shader node types with functions and instances, geometry nodes with fields, scattering and instancing, Bezier curves and paths, 3D text from TrueType fonts, landscapes (layers, erosion, paint layers, sea), the content library and Asset Browser (Poly Haven, SimReady), scene templates |
| Scripting and AI | BeeScript (the console, `--run` / `--eval`, macro recording, all 211 builtins), the MCP server and `--mcp-bridge` for AI agents with permission tiers and one-click revert, the AI Assistant (Claude Code, Grok, OpenRouter, Ollama), Ask AI on the selection, Tidy with AI, the reference line-up, the Image to 3D (Hi3D) addon |
| Collaboration | Versioned scenes (commit, branches, three-way merge, history, diff overlays), co-editing with host / join / follow and undo per author, the live link that mirrors a scene to another BeeModel, world partition with camera streaming and a minimap, the Versions editor |
| Files | `.bee` open / save / save as, file browser, Open Recent, "Save changes?"; OpenUSD import (`.usd` `.usda` `.usdc`: its own crate and text readers, stages composed with sublayers, references, payloads and variants, UsdPreviewSurface materials, rigid bodies and joints) |

## Layout

```
src/main.zig        entry, event loop, headless --shot driver
src/wayland.zig     Wayland wire-protocol client
src/keyboard.zig    XKB keymap parser, text input, layout-aware shortcuts
src/gfx.zig         canvas: fills, AA shapes, text, icons, triangle rasterizer
src/ttf.zig         TrueType parser and rasterizer;  src/text.zig  faces and glyph cache
src/ui.zig          immediate-mode UI core: widgets, tooltips, text editing, widget record
src/zuihost.zig     BeeZigUi (Zui, ../BeeZigUi): one Zui for the window, its dialogs and in-place parts
src/bkit.zig        the panel kit on Zui: sections, operator buttons, value and check rows
src/zuiprefs.zig    the Preferences (a dialog, or in an area), drawn by Zui
src/app.zig         the shell: areas, docking, workspaces, title / menu / status bars, input
src/menus.zig       menus, context menus, lists, the F3 palette
src/pies.zig        pie menus and the right-click wheel
src/dialogs.zig     About, Shortcuts, Undo History, the prompts (Save changes? ...), by Zui
src/editors.zig     viewport, tools, outliner, properties, console, timeline
src/colorpick.zig   the colour picker
src/filebrowser.zig the file browser;  src/files.zig  the document and file commands
src/bee.zig         .bee reader / writer
src/ops.zig         operator implementations bound to the catalog
src/xform.zig       modal G / R / S
src/undo.zig        undo / redo snapshots
src/mods.zig        the modifier stack: evaluation, cache, the file
src/modkern.zig     mirror, array, solidify, bevel, decimate, remesh;  src/subsurf.zig  Catmull-Clark
src/boolean.zig     exact mesh booleans;  src/pmesh.zig  the plain mesh they share
src/images.zig      the scene's images;  src/image.zig  src/jpeg.zig  src/exr.zig  codecs
src/env.zig         the HDRI world;  src/jobui.zig  long jobs in the status bar
src/scene.zig       objects, meshes (polygons), parents, selection
src/viewport.zig    3D view: camera, grid, meshes, outlines, gizmo, picking, image cache
src/hive.zig        the scene for the tracer: triangles, BVH;  src/pt.zig  the path tracer
src/render.zig      F12 and the Render editor;  src/denoise.zig  the denoiser
src/live.zig        Rendered shading: the live path-traced viewport
src/prefs.zig       preferences
src/theme.zig       the active theme;  src/expr.zig  expressions in fields
generated: src/catalog.zig src/themes.zig src/icons.zig src/keysyms.zig src/bee_icons.zig
```

The UI is moving onto BeeZigUi (`../BeeZigUi`, a path dependency in `build.zig.zon`), one
part at a time: [Docs/beezigui-migration.html](Docs/beezigui-migration.html) has the plan.
`src/zuihost.zig` runs one Zui frame per draw pass: dialogs are its clients, drawn over
everything; panels inside BeeModel's own layout are parts (`beginPart` / `endPart`), drawn
in place so BeeModel's menus still go over them. It takes input first, for what Zui
covered last frame, unless BeeModel's own UI is above it there. The rest of the UI, for now,
is one immediate-mode function (`app.frame`) run as a hit pass on each input event
and as a draw pass per frame.

## Tests

```
zig build test-ui              # the Zui host and the panel kit
tests/verify.sh OUTDIR [runs]   # all of it: builds, unit tests, scenarios, fuzzing, .bee round trip, benchmarks
tests/fuzz.py [runs] [seed]     # random sessions on the debug build
tests/fuzz_areas.py BIN N SEED  # area / panel / workspace heavy, small windows
tests/roundtrip.sh              # .bee files with the original binary (legacy: the original is no longer used)
```

`tests/scenarios.txt` holds the scripted scenarios. The `--shot` driver takes `--click-label
[kind:]label` (widgets by name, from `--dump-ui`), keys with modifiers, held keys, held
modifiers, waits (tooltips), `--render-wait` (F12 to its end), `--live-wait` (the Rendered viewport to
its last sample), `--keymap` and `--bench`. Headless runs never read or write
the preferences and write files only under `/tmp`.
