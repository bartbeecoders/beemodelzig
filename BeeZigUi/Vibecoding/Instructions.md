

You are an expert Zig systems programmer. Build a complete, production-oriented immediate-mode UI library called "Zui" (Zig UI) from scratch.

## Goals & Constraints
- Language: pure Zig (0.13+ / recent stable). Prefer no C/C++ dependencies in the core. If a backend needs them, isolate them behind a clean abstraction.
- Style: immediate-mode (Dear ImGui / Knots-like). User describes the UI every frame; library keeps minimal persistent state (focus, hover, scroll, open windows, etc.) keyed by ID.
- Memory: all allocations go through a user-provided `std.mem.Allocator`. No global allocators. Prefer arena-style or frame arenas where sensible.
- Performance: fast enough for tools, editors, and debug UIs. Avoid unnecessary allocations in the hot path.
- Cross-platform: Linux, Windows, macOS. Provide at least one working backend.
- API: clean, Zig-idiomatic, documented with doc comments. Use named fields / options structs where it improves readability.
- License: MIT.

Deliver a complete plan with phases that we can track (in a html file)
Work in small steps, delever working code after each step. Use demo apps that I can build and review (with easy to use run scripts)

## Core Architecture
1. **Context / Frame**
   - `Ui` struct that the user owns.
   - `beginFrame()` / `endFrame()` (or `startBuild` / `endBuild`).
   - Input: mouse position/buttons, scroll, keyboard, text input, window size, delta time.
   - Persistent state stored in the `Ui` (or a separate `State` object).

2. **Widgets (minimum viable set — implement all of these)**
   - Label / Text
   - Button (returns whether clicked / held / hovered)
   - Checkbox
   - Slider (float and int)
   - Text input (single-line)
   - Window / Panel (draggable, collapsible, with title bar)
   - SameLine / spacing / separator
   - Simple layout helpers (auto-layout vertically by default, optional horizontal groups)
   - Tooltip / popup basics
   - Color picker or at least color edit (optional but nice)

3. **Layout**
   - Cursor-based immediate layout (like ImGui).
   - Nesting support.
   - Padding, spacing, alignment options.
   - Grow / fixed sizing where practical.

4. **Styling**
   - Theme struct with colors (background, text, button, hover, active, border, etc.).
   - Default light and dark themes.
   - Ability to push/pop style overrides or set global style.

5. **Rendering Abstraction**
   - Define a simple `Renderer` interface / vtable (or function pointers) that the library calls:
     - Draw rect (filled + border)
     - Draw text (basic bitmap or vector is fine; start with a simple approach)
     - Clip rect
     - Optional: scissor, rounded rects later
   - Provide **at least one concrete backend**:
     - Preferred: a simple software/CPU rasterizer backend that can be used with any windowing library, **or**
     - An OpenGL backend using minimal C bindings (or pure Zig if feasible), **or**
     - Integration notes + example for raylib / GLFW / sokol.
   - The core library must compile and be usable without the backend; the backend is a separate module or example.

6. **Input & Interaction**
   - Hit testing, hover, active, focus.
   - Keyboard navigation basics (tab, arrows, enter/escape) for the most important widgets.
   - Mouse capture when dragging (sliders, window move).

## Project Structure (create all of this)
zui/ ├── build.zig ├── build.zig.zon ├── README.md ├── LICENSE ├── src/ │ ├── root.zig // public API │ ├── ui.zig // main Ui context │ ├── widgets.zig // all widgets │ ├── layout.zig │ ├── style.zig │ ├── input.zig │ ├── draw.zig // draw commands / renderer interface │ └── internal/ // private helpers ├── examples/ │ └── demo/ │ ├── main.zig // full demo window showing every widget │ └── build integration └── tests/ // unit tests for layout math, hit testing, etc. where practical


## Requirements for the generated code
- Full, compilable code. Do not leave stubs or “TODO: implement”.
- Idiomatic Zig: error handling with `!`, `defer`, explicit allocators, comptime where it helps, no unnecessary runtime overhead.
- Doc comments on every public function and type.
- A working demo that opens a window and shows buttons, sliders, checkboxes, text input, a draggable window, and style switching.
- Clear README with:
  - Quick start
  - How to add the library as a dependency
  - Basic usage example
  - How the renderer backend works
  - Known limitations and next steps

## Implementation order (follow this)
1. Core types (`Ui`, style, input, draw commands).
2. Basic layout + label + button.
3. Window / panel.
4. Remaining widgets (checkbox, slider, text input).
5. Style system + themes.
6. One concrete renderer backend + demo.
7. Polish, tests, and README.

## Extra nice-to-haves (implement if time allows)
- Rounded corners / simple shadows in the draw layer.
- Tree node / collapsing header.
- Basic table or list view.
- Hot-reload friendly design.

Start by creating the full project structure and implementing the core + demo so that `zig build` in the examples/demo directory produces a runnable binary that shows a working UI.

Make the library something a Zig developer would actually want to depend on for tools and debug interfaces.