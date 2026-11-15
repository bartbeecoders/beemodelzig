#!/usr/bin/env bash
# Zui demo runner. See ./run.sh help
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Zig 0.17.1 is required; prefer the mise-pinned install so no global default is needed.
if command -v mise >/dev/null 2>&1; then
    zig() { mise exec zig@0.17.1 -- zig "$@"; }
elif ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found. Install Zig 0.17.1 (https://ziglang.org/download/)." >&2
    exit 1
fi

examples() { find examples -mindepth 1 -maxdepth 1 -type d ! -name common -printf '%f\n' | sort; }

usage() {
    cat <<USAGE
Usage: ./run.sh <command> [args]

  <demo> [args]   Build (ReleaseFast) and run a demo
  list            List the demos
  test            Run the unit tests
  docs            Check that every public declaration has a doc comment
  bench [N W H]   Time N frames of a busy UI at W x H (default 1000 1280 800)
  gl-check        Compare the OpenGL renderer with the software one, pixel by pixel
  native [args]   Run the demo on the native backend: Wayland (no libc) or Win32
  cross           Compile-check the core for Windows and macOS
  scenarios       Play the scripts in tests/scenarios against their demos
  check           test + docs + cross + scenarios: everything before a release
  shot <demo>     Render a phase demo without a window to shots/<demo>.png
  build           Build every demo into zig-out/bin
  help            Show this help

Demos:
$(examples | sed 's/^/  /')

Start with:  ./run.sh demo
Phase demos (01_* to 25_*) accept:  --frames N   quit after N frames
                                    --shot FILE  render off-screen to a PNG
                                    --gl         draw with OpenGL
                                    --scale S    render the PNG at S pixels per unit
                                    --script F   play a script, no window
                                    --dump-ui    print the widgets as JSON
demo accepts --gl too.
12_hot_reload: edit examples/12_hot_reload/app.zig while it runs, then
               run "zig build hot-app" to swap in the new code.
render_png takes an output path:    ./run.sh render_png out.png
USAGE
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
    help | -h | --help) usage ;;
    list) examples ;;
    test) zig build test --summary all "$@" ;;
    build) zig build -Doptimize=ReleaseFast "$@" ;;
    cross) zig build cross --summary all "$@" ;;
    docs) zig build check-docs "$@" ;;
    bench) zig build bench -- "$@" ;;
    gl-check) zig build gl-check "$@" ;;
    native) zig build native -Doptimize=ReleaseSafe -- "$@" ;;
    scenarios) zig build scenarios --summary all "$@" ;;
    check)
        zig build test --summary all
        zig build check-docs
        zig build cross --summary all
        zig build scenarios --summary all
        ;;
    shot)
        demo="${1:?usage: ./run.sh shot <demo>}"
        mkdir -p shots
        zig build "run-$demo" -Doptimize=ReleaseFast -- --shot "shots/$demo.png"
        echo "wrote shots/$demo.png"
        ;;
    *)
        if ! examples | grep -qx "$cmd"; then
            echo "error: unknown command or demo '$cmd'" >&2
            usage >&2
            exit 1
        fi
        zig build "run-$cmd" -Doptimize=ReleaseFast -- "$@"
        ;;
esac
