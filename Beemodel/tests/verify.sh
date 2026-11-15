#!/usr/bin/env bash
# The checks every step runs (the review agents use them too):
#   1. builds: debug (safety checks) into zig-out-debug, release into zig-out
#   2. unit tests (zig test on the modules that have them; zig build test-ui for the Zui host)
#   3. scenarios: tests/scenarios.txt rendered headless to PNGs (+ ui dumps)
#   4. stability: tests/fuzz.py random sessions on the debug build
#   5. performance: frame times at 1280x800 and 2560x1440 (release)
#
#   tests/verify.sh [out-dir] [fuzz-runs]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/beemodel-verify}"
RUNS="${2:-300}"
mkdir -p "$OUT"
if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == 0.17* ]]; then ZIG=(zig); else ZIG=(mise exec -- zig); fi
# Every program this gate starts gets XDG folders of its own: the user's shell points
# XDG_CACHE_HOME / CONFIG / DATA / STATE / RUNTIME_DIR at the real ones, and both
# programs autosave into the cache and put their MCP socket in the runtime dir.
# zig's own cache and mise's installs stay where they are.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}"
export MISE_DATA_DIR="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
GATE_XDG="$(mktemp -d /tmp/beexdg-XXXXXX)"
trap 'rm -rf -- "$GATE_XDG"' EXIT
mkdir -p -m 700 "$GATE_XDG/cache" "$GATE_XDG/config" "$GATE_XDG/data" "$GATE_XDG/state" "$GATE_XDG/run"
unset WAYLAND_DISPLAY DISPLAY   # (no test reaches the user's desktop; window tests bring a fake compositor)
export XDG_CACHE_HOME="$GATE_XDG/cache" XDG_CONFIG_HOME="$GATE_XDG/config" XDG_DATA_HOME="$GATE_XDG/data" XDG_STATE_HOME="$GATE_XDG/state" XDG_RUNTIME_DIR="$GATE_XDG/run"
fail=0

echo "== build"
"${ZIG[@]}" build -p zig-out-debug || { echo "debug build FAILED"; exit 1; }
"${ZIG[@]}" build --release=fast || { echo "release build FAILED"; exit 1; }
ls -l zig-out/bin/beemodel | awk '{print "release binary: " $5 " bytes"}'

echo "== unit tests"
for f in src/expr.zig src/material.zig src/pt.zig src/png.zig src/jobs.zig src/probe.zig src/refclass.zig src/refset.zig src/apng.zig src/spawn.zig src/texture.zig src/shgraph.zig src/shgraph_oracle.zig src/graphops.zig src/surface.zig src/bake.zig src/vgeo.zig src/scale.zig src/keys.zig src/wg.zig src/forms.zig src/outfolders.zig src/atomicfile.zig src/autosave.zig src/wsfile.zig src/prims.zig src/redo.zig src/analysis.zig src/thumb.zig src/drop.zig src/objmtl.zig src/animexpr.zig src/anim.zig src/arm.zig src/rig.zig src/uv.zig src/stroke.zig src/sculpt.zig src/sculptui.zig src/vcol.zig src/layers.zig src/wpaint.zig src/pthist.zig src/paint.zig src/dyntopo.zig src/multires.zig src/cad.zig src/fab.zig src/sdf.zig src/print.zig src/measure.zig src/sketch.zig src/skobj.zig src/fab2d.zig src/sketchui.zig src/fmesh.zig src/prof.zig src/feature.zig src/nurbs.zig src/brep.zig src/btess.zig src/proftri.zig src/stepread.zig src/step.zig src/bbuild.zig src/bssi.zig src/bbool.zig src/bfeat.zig src/bfillet.zig src/lcam.zig src/mech.zig src/viewport.zig src/rbcore.zig src/simcache.zig src/rbshape.zig src/rbsolve.zig src/rbnarrow.zig src/collide.zig src/clip.zig src/nbody.zig src/rbody.zig src/fields.zig src/shatter.zig src/shatterop.zig src/shatterui.zig src/cloth.zig src/particles.zig src/liquid.zig src/partdraw.zig src/ntree.zig src/logic.zig src/alloc.zig src/shnodes.zig src/fieldvm.zig src/geonodes.zig src/inst.zig src/curve.zig src/text3d.zig src/procgen.zig src/landscape.zig src/lsculpt.zig src/landio.zig src/landui.zig src/rbland.zig src/rbimp.zig src/library.zig src/asset.zig src/libui.zig src/extlib.zig src/nodeed.zig src/menus.zig src/bscript.zig src/json.zig src/agent.zig src/mcp.zig src/bs_phys.zig src/bs_play.zig src/bs_net.zig src/bs_mat.zig src/bs_nodes.zig src/bs_render.zig src/bs_paint.zig src/wfc.zig src/undo.zig src/bs_cad.zig src/bs_sketch.zig src/bs_sdf.zig src/bs_model.zig src/copilot.zig src/hi3d.zig src/aiproc.zig src/ai.zig src/aiask.zig src/link.zig src/world.zig src/vc.zig src/cosync.zig src/cotree.zig src/usdlayer.zig src/usdc.zig src/usda.zig src/m4d.zig src/scene.zig src/gltf.zig src/pngenc.zig; do "${ZIG[@]}" test "$f" 2>&1 | tail -1 || { echo "unit test $f FAILED"; fail=1; }; done
"${ZIG[@]}" build test-ui || { echo "unit tests of the Zui host and panel kit FAILED"; fail=1; }

echo "== scenarios -> $OUT"
SCN_HOME="$(mktemp -d /tmp/beescn-XXXXXX)"
while IFS='|' read -r name args; do
    name="$(echo "$name" | xargs)"
    [[ -z "$name" || "$name" == \#* ]] && continue
    eval "set -- $args"
    if ! HOME="$SCN_HOME" ./zig-out-debug/bin/beemodel --shot "$OUT/$name.ppm" --dump-ui "$OUT/$name.ui.txt" "$@" 2> "$OUT/$name.err"; then
        echo "scenario $name FAILED: $(tail -2 "$OUT/$name.err")"; fail=1
    fi
    if command -v magick >/dev/null; then magick "$OUT/$name.ppm" "$OUT/$name.png" && rm "$OUT/$name.ppm"; fi
done < tests/scenarios.txt
rm -rf "$SCN_HOME"
echo "$(ls "$OUT"/*.png 2>/dev/null | wc -l) screenshots"

echo "== stability ($RUNS random sessions, debug build)"
BEEMODEL_BIN=./zig-out-debug/bin/beemodel python3 tests/fuzz.py "$RUNS" || fail=1
python3 tests/fuzz_edit.py ./zig-out-debug/bin/beemodel "$((RUNS / 2))" "$RANDOM" | tail -3 | grep -q "fails 0" || { echo "edit fuzz FAILED"; fail=1; }
python3 tests/fuzz_areas.py ./zig-out-debug/bin/beemodel "$((RUNS / 2))" "$RANDOM" | tail -3 | grep -q "fails 0" || { echo "area fuzz FAILED"; fail=1; }

BEEMODEL_BIN=./zig-out-debug/bin/beemodel python3 tests/fuzz_tex.py "$RUNS" "$RANDOM" || fail=1

echo "== .bee files"
tests/roundtrip.sh || fail=1
tests/texture.sh ./zig-out/bin/beemodel || fail=1

echo "== light probes and lightmaps, damaged chunks (release)"
BEEMODEL_BIN=./zig-out/bin/beemodel python3 tests/bake.py "$((RUNS / 3))" || fail=1

echo "== virtualized geometry, damaged chunks"
{ python3 -c 'import numpy' 2>/dev/null && BEEMODEL_BIN=./zig-out-debug/bin/beemodel python3 tests/vgeo.py "$((RUNS / 10))" || fail=1; }

echo "== the window against a fake compositor, threads and scale"
python3 tests/jobs_wl.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "jobs in a window FAILED"; fail=1; }
python3 tests/wl.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "wl FAILED"; fail=1; }
python3 tests/uishell.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "uishell FAILED"; fail=1; }

echo "== reference images and animation output"
{ BEEMODEL_BIN=./zig-out-debug/bin/beemodel python3 tests/refvideo.py | tail -1 | grep -q "fails 0" || { echo "refvideo FAILED"; fail=1; }; }

echo "== the animation: channels, files, undo, damaged chunks, a window"
{ python3 tests/anim.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "anim FAILED"; fail=1; }; }

echo "== the rig: matrices, skin, weights, IK, constraints, files, damaged chunks, keys in a window"
{ python3 tests/rig.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "rig FAILED"; fail=1; }; }

echo "== UV maps and the UV editor: UVs, seams, files, undo, the look, damaged chunks, baking"
{ python3 tests/review8.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "review8 FAILED"; fail=1; }; }
{ python3 tests/uv.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "uv FAILED"; fail=1; }; }

echo "== sculpt mode: strokes, undo, the window, a pen, damaged input"
{ python3 tests/sculpt.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "sculpt FAILED"; fail=1; }; }

echo "== painting: texels, colours, weights, layers, undo, the window, a pen, damaged input"
{ python3 tests/paint.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "paint FAILED"; fail=1; }; }

echo "== dynamic topology: the same triangles, undo, files, the window, the strange and the damaged"
{ python3 tests/dyntopo.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "dyntopo FAILED"; fail=1; }; }

echo "== CAD: units, parameters, measure, print check, 3MF, PDF, signed distance, damaged chunks, the window"
{ BEECAD_TMP=/tmp python3 tests/cad.py ./zig-out-debug/bin/beemodel "$((RUNS / 20 + 1))" 2>&1 | tee "$OUT/cad.log" | tail -1 | grep -q "fails 0" || { echo "cad FAILED"; fail=1; }; }

echo "== sketches: the solver, files, DXF / SVG, sketch mode, the window, damaged input"
{ python3 tests/sketch.py ./zig-out-debug/bin/beemodel "$((RUNS / 3))" 2>&1 | tee "$OUT/sketch.log" | tail -1 | grep -q "fails 0" || { echo "sketch FAILED"; fail=1; }; }

echo "== the feature tree: random chains, files, failures, undo, the CAD tab, the template, the window"
{ python3 tests/feature.py ./zig-out-debug/bin/beemodel "$((RUNS / 8))" 2>&1 | tee "$OUT/feature.log" | tail -1 | grep -q "fails 0" || { echo "feature FAILED"; fail=1; }; }

echo "== the B-rep kernel and STEP: solids, booleans, tessellation, import / export bytes, damaged STEP"
{ python3 tests/brep.py ./zig-out-debug/bin/beemodel "$((RUNS / 8))" 2>&1 | tee "$OUT/brep.log" | tail -1 | grep -q "fails 0" || { echo "brep FAILED"; fail=1; }; }
{ python3 tests/step.py ./zig-out-debug/bin/beemodel "$((RUNS / 8))" 2>&1 | tee "$OUT/step.log" | tail -1 | grep -q "fails 0" || { echo "step FAILED"; fail=1; }; }

echo "== features as B-rep solids: kernel on, fillets and chamfers, STEP of feature bodies, undo, files, the window"
{ BEE_CPU=10 python3 tests/bfeat.py ./zig-out-debug/bin/beemodel "$((RUNS / 10))" 2>&1 | tee "$OUT/bfeat.log" | tail -1 | grep -q "fails 0" || { echo "bfeat FAILED"; fail=1; }; }

echo "== layer 2 review: persistent uids, duplicate, empty STEP solids, the colour field, Esc in a STEP import"
{ python3 tests/review10.py ./zig-out-debug/bin/beemodel "$((RUNS / 15))" 2>&1 | tee "$OUT/review10.log" | tail -1 | grep -q "fails 0" || { echo "review10 FAILED"; fail=1; }; }
echo "== review 11: ANIM uids of deleted objects, PRNT of a deleted parent, LCAM records, light.set / camera.set"
{ BEE_CPU=14 python3 tests/review11.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/review11.log" | tail -1 | grep -q "fails 0" || { echo "review11 FAILED"; fail=1; }; }
echo "== mechanisms: joints, gears, racks, limits, parameter channels, collisions, mates, files, undo, damaged records, the window"
{ MECH_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/mech.py ./zig-out-debug/bin/beemodel 30 2>&1 | tee "$OUT/mech.log" | tail -1 | grep -q "fails 0" || { echo "mech FAILED"; fail=1; }; }
echo "== rigid bodies: shapes, joints, a pile, attraction, fields, the cache and SIMC, damaged records, undo with the timeline, fuzz, timing"
{ RB_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/rbody.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/rbody.log" | tail -1 | grep -q "fails 0" || { echo "rbody FAILED"; fail=1; }; }
echo "== force fields: pulls, presets, groups, FLDS, damaged chunks, the overlay, the Force Field section"
{ FIELDS_REL=./zig-out/bin/beemodel BEE_CPU=14 python3 tests/fields.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/fields.log" | tail -1 | grep -q "fails 0" || { echo "fields FAILED"; fail=1; }; }
echo "== shatter: shards, bricks, balls, presets, glue, pieces byte for byte, separate loose, the Shatter section"
{ SHATTER_REL=./zig-out/bin/beemodel BEE_CPU=10 python3 tests/shatter.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/shatter.log" | tail -1 | grep -q "fails 0" || { echo "shatter FAILED"; fail=1; }; }
echo "== cloth and soft bodies: random scenes, threads, the cache, MPIN, damaged records, undo with the timeline, the Cloth section, fuzz, timing, memory"
{ CL_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/cloth.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/cloth.log" | tail -1 | grep -q "fails 0" || { echo "cloth FAILED"; fail=1; }; }
echo "== particles and liquid: emission, fields, collisions, liquids, threads, words, PSYS / SIMC, damaged chunks, the surface, fuzz, timing"
{ PT_REL=./zig-out/bin/beemodel BEE_CPU=14 python3 tests/particles.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/particles.log" | tail -1 | grep -q "fails 0" || { echo "particles FAILED"; fail=1; }; }
echo "== the Particles tab and drawn particles: the look and the widgets"
{ BEE_CPU=14 python3 tests/particles_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/particles_wl.log" | tail -1 | grep -q "fails 0" || { echo "particles_wl FAILED"; fail=1; }; }
echo "== play mode: walking, edges, planets, riding, keys, restore, the HUD in the window, fuzz, timing, memory"
{ PLAY_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/play.py ./zig-out-debug/bin/beemodel 4 2>&1 | tee "$OUT/play.log" | tail -1 | grep -q "fails 0" || { echo "play FAILED"; fail=1; }; }
echo "== logic graphs: ops, every node, random graphs, a message storm, damaged NTRE, files, undo, fuzz"
{ BEE_CPU=12 python3 tests/logic.py ./zig-out-debug/bin/beemodel 4 2>&1 | tee "$OUT/logic.log" | tail -1 | grep -q "fails 0" || { echo "logic FAILED"; fail=1; }; }
echo "== phase 11: shader nodes, geometry nodes, curves, 3D text, landscapes, landscape colliders, impact shatter"
{ BEE_CPU=12 python3 tests/shnodes.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/shnodes.log" | tail -1 | grep -q "fails 0" || { echo "shnodes FAILED"; fail=1; }; }
{ GN_REL=./zig-out/bin/beemodel BEE_CPU=14 python3 tests/geonodes.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/geonodes.log" | tail -1 | grep -q "fails 0" || { echo "geonodes FAILED"; fail=1; }; }
{ CV_REL=./zig-out/bin/beemodel BEE_CPU=10 python3 tests/curves.py ./zig-out-debug/bin/beemodel 6 2>&1 | tee "$OUT/curves.log" | tail -1 | grep -q "fails 0" || { echo "curves FAILED"; fail=1; }; }
{ BEE_CPU=10 python3 tests/curves_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/curves_wl.log" | tail -1 | grep -q "fails 0" || { echo "curves_wl FAILED"; fail=1; }; }
{ TX_REL=./zig-out/bin/beemodel BEE_CPU=10 python3 tests/text3d.py ./zig-out-debug/bin/beemodel 6 2>&1 | tee "$OUT/text3d.log" | tail -1 | grep -q "fails 0" || { echo "text3d FAILED"; fail=1; }; }
{ BEE_CPU=10 python3 tests/text3d_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/text3d_wl.log" | tail -1 | grep -q "fails 0" || { echo "text3d_wl FAILED"; fail=1; }; }
{ LA_REL=./zig-out/bin/beemodel BEE_CPU=14 python3 tests/landscape.py ./zig-out-debug/bin/beemodel 3 2>&1 | tee "$OUT/landscape.log" | tail -1 | grep -q "fails 0" || { echo "landscape FAILED"; fail=1; }; }
{ BEE_CPU=14 python3 tests/procgen.py ./zig-out-debug/bin/beemodel 6 2>&1 | tee "$OUT/procgen.log" | tail -1 | grep -q "fails 0" || { echo "procgen FAILED"; fail=1; }; }
{ BEE_CPU=14 python3 tests/landscape_wl.py ./zig-out/bin/beemodel 2>&1 | tee "$OUT/landscape_wl.log" | tail -1 | grep -q "fails 0" || { echo "landscape_wl FAILED"; fail=1; }; }
{ BEE_CPU=14 python3 tests/landio.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/landio.log" | tail -1 | grep -q "fails 0" || { echo "landio FAILED"; fail=1; }; }
{ BEE_CPU=14 python3 tests/landui_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/landui_wl.log" | tail -1 | grep -q "fails 0" || { echo "landui_wl FAILED"; fail=1; }; }
{ RB_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/rbland.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/rbland.log" | tail -1 | grep -q "fails 0" || { echo "rbland FAILED"; fail=1; }; }
echo "== phase 11 layer 2: the node editor, the libraries"
{ BEE_CPU=10 python3 tests/nodeed.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/nodeed.log" | tail -1 | grep -q "fails 0" || { echo "nodeed FAILED"; fail=1; }; }
{ LB_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/library.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/library.log" | tail -1 | grep -q "fails 0" || { echo "library FAILED"; fail=1; }; }
{ BEE_CPU=14 python3 tests/extlib.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/extlib.log" | tail -1 | grep -q "fails 0" || { echo "extlib FAILED"; fail=1; }; }
echo "== menus and submenus: the look and the widgets"
{ BEE_CPU=12 python3 tests/menus_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/menus_wl.log" | tail -1 | grep -q "fails 0" || { echo "menus_wl FAILED"; fail=1; }; }
echo "== phase 12: BeeScript (language, console, macros, --run / --eval)"
{ BEE_CPU=10 python3 tests/bscript.py ./zig-out-debug/bin/beemodel 150 2>&1 | tee "$OUT/bscript.log" | tail -1 | grep -q "fails 0" || { echo "bscript FAILED"; fail=1; }; }
{ BEE_CPU=10 python3 tests/bscript_perf.py ./zig-out/bin/beemodel 2>&1 | tee "$OUT/bscript_perf.log" | tail -1 | grep -q "fails 0" || { echo "bscript_perf FAILED"; fail=1; }; }
echo "== phase 12: the MCP server, material tools, agent permissions, AI Activity, --mcp-bridge"
{ MCP_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/mcp.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/mcp.log" | tail -1 | grep -q "fails 0" || { echo "mcp FAILED"; fail=1; }; }
echo "== phase 12: BeeScript builtins for physics, landscapes, animation, rigs, play and logic, and the phase 13 stubs"
{ BEE_CPU=8 python3 tests/bs_sim.py ./zig-out-debug/bin/beemodel 60 2>&1 | tee "$OUT/bs_sim.log" | tail -1 | grep -q "fails 0" || { echo "bs_sim FAILED"; fail=1; }; }
echo "== phase 12: BeeScript builtins for materials, nodes, render, paint / UV / sculpt, libraries, curves and procedural"
for t in "bs_mat 150" "bs_render 150" "bs_paint 60" "bs_proc 60" "bs_lib 60"; do set -- $t
  { BEE_CPU=14 python3 tests/$1.py ./zig-out-debug/bin/beemodel $2 2>&1 | tee "$OUT/$1.log" | tail -1 | grep -q "fails 0" || { echo "$1 FAILED"; fail=1; }; }
done
{ BEE_CPU=14 python3 tests/bs_window.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/bs_window.log" | tail -1 | grep -q "fails 0" || { echo "bs_window FAILED"; fail=1; }; }
echo "== phase 12: BeeScript builtins for CAD, sketches, SDF and modelling"
for t in bs_cad bs_sketch bs_sdf bs_model bs_cad_fuzz; do
  { BEE_CPU=10 python3 tests/$t.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/$t.log" | tail -1 | grep -q "fails 0" || { echo "$t FAILED"; fail=1; }; }
done
{ BEE_CPU=10 python3 tests/bs_cad_perf.py ./zig-out/bin/beemodel 2>&1 | tee "$OUT/bs_cad_perf.log" | tail -1 | grep -q "fails 0" || { echo "bs_cad_perf FAILED"; fail=1; }; }
echo "== phase 12: the co-pilot (proposals, node catalogue, prompts), Tidy, the reference line-up and Image to 3D"
for t in copilot aitools; do
  { BEE_CPU=14 python3 tests/$t.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/$t.log" | tail -1 | grep -q "fails 0" || { echo "$t FAILED"; fail=1; }; }
done
echo "== phase 12: the AI Assistant (Claude Code, Grok, OpenRouter, Ollama) and Ask AI, on fake CLIs and a local fake server"
{ BEE_CPU=12 python3 tests/ai.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/ai.log" | tail -1 | grep -q "fails 0" || { echo "ai FAILED"; fail=1; }; }
echo "== phase 13: versioned scenes, co-editing, the live link, world partition (loopback only)"
{ BEE_CPU=8 python3 tests/vc.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/vc.log" | tail -1 | grep -q "fails 0" || { echo "vc FAILED"; fail=1; }; }
{ BEE_CPU=10 python3 tests/coedit.py ./zig-out-debug/bin/beemodel 200 2>&1 | tee "$OUT/coedit.log" | tail -1 | grep -q "fails 0" || { echo "coedit FAILED"; fail=1; }; }
{ LL_REL=./zig-out/bin/beemodel BEE_CPU=12 python3 tests/livelink.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/livelink.log" | tail -1 | grep -q "fails 0" || { echo "livelink FAILED"; fail=1; }; }
{ WORLD_REL=./zig-out/bin/beemodel BEE_CPU=14 python3 tests/world.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/world.log" | tail -1 | grep -q "fails 0" || { echo "world FAILED"; fail=1; }; }
echo "== the USD import: crate and text readers, composition, materials, physics, damaged files, the window, timing (against OpenUSD)"
{ BEE_CPU=8 python3 tests/usd.py ./zig-out-debug/bin/beemodel 200 2>&1 | tee "$OUT/usd.log" | tail -1 | grep -q "fails 0" || { echo "usd FAILED"; fail=1; }; }
{ BEE_CPU=8 python3 tests/usd_perf.py ./zig-out/bin/beemodel 5 2>&1 | tee "$OUT/usd_perf.log" | tail -1 | grep -q "fails 0" || { echo "usd_perf FAILED"; fail=1; }; }
echo "== glTF import and export: generated files, byte-identical exports, maps and lightmaps, round trips, damaged files, the window, timing"
{ BEE_CPU=8 python3 tests/gltf.py ./zig-out-debug/bin/beemodel 200 2>&1 | tee "$OUT/gltf.log" | tail -1 | grep -q "fails 0" || { echo "gltf FAILED"; fail=1; }; }
{ BEE_CPU=8 python3 tests/gltf_perf.py ./zig-out/bin/beemodel 5 2>&1 | tee "$OUT/gltf_perf.log" | tail -1 | grep -q "fails 0" || { echo "gltf_perf FAILED"; fail=1; }; }
echo "== the Physics tab: the look and the widgets"
{ BEE_CPU=12 python3 tests/physui_wl.py ./zig-out-debug/bin/beemodel 2>&1 | tee "$OUT/physui.log" | tail -1 | grep -q "fails 0" || { echo "physui FAILED"; fail=1; }; }
echo "== phase 9 review: near-plane clipping, SKCH refs after undo, the Light / Camera panels, the CAD tab"
{ BEE_CPU=12 python3 tests/review12.py ./zig-out-debug/bin/beemodel 20 2>&1 | tee "$OUT/review12.log" | tail -1 | grep -q "fails 0" || { echo "review12 FAILED"; fail=1; }; }

echo "== multires: every level, displacements, the stack, undo, files, damaged blocks"
{ python3 tests/multires.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "multires FAILED"; fail=1; }; }

echo "== autosave by killing the process, workspaces, primitives, redo panel, analysis, files"
{
    python3 tests/autosave.py ./zig-out-debug/bin/beemodel 40 | tail -1 | grep -q "fails 0" || { echo "autosave FAILED"; fail=1; }
    python3 tests/wspc.py ./zig-out-debug/bin/beemodel "$((RUNS / 3))" | tail -1 | grep -q "fails 0" || { echo "wspc FAILED"; fail=1; }
    python3 tests/prims.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "prims FAILED"; fail=1; }
    python3 tests/redopanel.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "redopanel FAILED"; fail=1; }
    python3 tests/analysis.py ./zig-out-debug/bin/beemodel 60 | tail -1 | grep -q "fails 0" || { echo "analysis FAILED"; fail=1; }
    python3 tests/files6.py ./zig-out-debug/bin/beemodel | tail -1 | grep -q "fails 0" || { echo "files6 FAILED"; fail=1; }
    python3 tests/objmtl.py ./zig-out-debug/bin/beemodel "$((RUNS / 5))" | tail -1 | grep -q "fails 0" || { echo "objmtl FAILED"; fail=1; }
}
./zig-out-debug/bin/beemodel --selftest | tail -1 | grep -q "all self-tests passed" || { echo "selftest FAILED"; fail=1; }

echo "== the GPU helper against the CPU (skips itself with no device)"
python3 tests/gpu.py ./zig-out-debug/bin/beemodel || fail=1

echo "== performance (release)"
./zig-out/bin/beemodel --shot "$OUT/bench.ppm" --size 1280x800 --bench 120
./zig-out/bin/beemodel --shot "$OUT/bench.ppm" --size 2560x1440 --bench 60
./zig-out/bin/beemodel --shot "$OUT/bench.ppm" --size 2560x1440 --click-label menu:View --move-label menuitem:Theme --bench 60
rm -f "$OUT/bench.ppm"

[[ $fail == 0 ]] && echo "== ALL CHECKS PASSED" || echo "== SOME CHECKS FAILED"
exit $fail
