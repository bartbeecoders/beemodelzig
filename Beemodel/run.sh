#!/usr/bin/env bash
# Build (if needed) and start BeeModel - Zig prototype.
#
#   ./run.sh                 build ReleaseFast and open the window
#   ./run.sh debug           build with safety checks + debug info, then run
#   ./run.sh --shot out.ppm  render one frame headless (no compositor needed)
#
# Needs Zig 0.17.x: on PATH, or installed through mise (mise.toml pins it).
set -euo pipefail
cd "$(dirname "$0")"

want="0.17"
if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == ${want}* ]]; then
    ZIG=(zig)
elif command -v mise >/dev/null 2>&1; then
    mise install --quiet zig >/dev/null 2>&1 || true
    ZIG=(mise exec -- zig)
else
    echo "run.sh: Zig ${want}.x not found. Install it (https://ziglang.org/download/ or 'mise use zig@0.17.1')." >&2
    exit 1
fi

mode=(--release=fast)
if [[ "${1:-}" == "debug" ]]; then
    mode=()
    shift
fi

"${ZIG[@]}" build "${mode[@]}"
exec ./zig-out/bin/beemodel "$@"
