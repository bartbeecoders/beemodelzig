#!/usr/bin/env bash
# Runs the reproductions behind Docs/improvements.html. They are not part of
# the build: each one shows a problem from that list, so a test that FAILS or
# PANICS here is the problem still being there; once it is fixed, the test
# passes (and should then move into tests/ as a regression test).
#
#   Docs/repro/run.sh                 every reproduction
#   Docs/repro/run.sh core/t.zig      one of them
#   Docs/repro/run.sh bench           the renderer benchmark: today's against the prototype (render/sw2.zig)
set -uo pipefail
cd "$(dirname "$0")/../.."
R=Docs/repro
if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == 0.17* ]]; then ZIG=(zig); else ZIG=(mise exec -- zig); fi

zui=(-Mzui=src/root.zig)
sw=(--dep zui -Mzui_software=backends/software.zig)
nodes=(--dep zui -Mzui_nodes=addons/nodes.zig)

run() {
    local f="$1"
    echo "== $f"
    case "$f" in
        core/*.zig | widgets/*.zig | backends/mv.zig | backends/sc.zig | backends/sc2.zig)
            "${ZIG[@]}" test --dep zui -Mroot="$R/$f" "${zui[@]}" ;;
        render/t.zig)
            "${ZIG[@]}" test --dep zui --dep zui_software -Mroot="$R/$f" "${sw[@]}" "${zui[@]}" ;;
        backends/km.zig)
            "${ZIG[@]}" test --dep zui --dep km -Mroot="$R/$f" --dep zui -Mkm=backends/wayland/keymap.zig "${zui[@]}" ;;
        backends/wl.zig)
            "${ZIG[@]}" test --dep zui --dep zui_software --dep wl -Mroot="$R/$f" "${sw[@]}" --dep zui --dep zui_software -Mwl=backends/wayland.zig "${zui[@]}" ;;
        *) echo "  (a program, not a test: see the top of the file)" ;;
    esac
}

bench() {
    local out; out="$(mktemp -d)"
    "${ZIG[@]}" build-exe -OReleaseFast -femit-bin="$out/prof" --dep zui --dep zui_software --dep zui_nodes --dep sw2 \
        -Mroot="$R/render/prof.zig" "${sw[@]}" "${nodes[@]}" --dep zui -Msw2="$R/render/sw2.zig" "${zui[@]}" || return 1
    echo "== widgets, today's renderer";  "$out/prof" 500 1280 800 x ""  | grep -E "render"
    echo "== widgets, prototype";         "$out/prof" 500 1280 800 x s   | grep -E "render"
    echo "== widgets, pixels compared";   "$out/prof" 500 1280 800 x c   | grep -E "differ"
    echo "== nodes, today's renderer";    "$out/prof" 200 1280 800 nodes ""  | grep -E "render"
    echo "== nodes, prototype";           "$out/prof" 200 1280 800 nodes s   | grep -E "render"
    echo "== nodes, pixels compared";     "$out/prof" 200 1280 800 nodes c   | grep -E "differ"
    rm -rf "$out"
}

if [[ $# -eq 0 ]]; then
    for f in core/t.zig core/perf.zig widgets/values.zig widgets/lists.zig widgets/dialog_escape.zig widgets/dock.zig \
             widgets/textarea.zig widgets/choice.zig widgets/expr.zig render/t.zig backends/km.zig backends/wl.zig \
             backends/mv.zig backends/sc.zig backends/sc2.zig; do
        run "$f" 2>&1 | grep -E "^==|passed|failed|panic|OK$|FAIL" | head -12
    done
elif [[ "$1" == bench ]]; then
    bench
else
    run "$1"
fi
