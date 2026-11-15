#!/usr/bin/env bash
# .bee round trips through BeeModel alone: a scene made in the window and saved
# must open again (--eval) with the same objects, positions (world), parents
# and settings; a scene saved by --eval must open in the window; and
# save -> open -> save gives the same file.
#
#     tests/roundtrip.sh [BIN]
set -uo pipefail
[[ -n ${1:-} ]] && BIN=$(realpath "$1")
cd "$(dirname "$0")/.."
# a HOME of its own: the user's ~/.config stays as it is
export HOME="$(mktemp -d /tmp/beehome-XXXXXX)"
trap 'rm -rf "$HOME"' EXIT
unset WAYLAND_DISPLAY DISPLAY
BIN=${BIN:-./zig-out-debug/bin/beemodel}
[[ -x $BIN ]] || { echo "roundtrip: no binary at $BIN"; exit 1; }
T=$(mktemp -d)
"$BIN" --shot "$T/a.ppm" --move 615,360 --shift-key a --click-label "menuitem:UV Sphere" \
  --move 615,360 --key g --key x --type 3 --key enter --click-label row:Light --click-label enum:Point --click-label menuitem:Spot \
  --click-label row:Camera --mods ctrl --click-label row:Cube --mods none --move 615,360 --key ctrl+p \
  --key g --key y --type 2 --key enter --key enter --type "file.save $T/z.bee" --key enter || exit 1
got=$("$BIN" --eval "op(\"file.open\", \"$T/z.bee\"); print(count(), name(3), get(\"Sphere\",\"x\"), faces(\"Sphere\"), get(\"Camera\",\"y\") + get(\"Cube\",\"y\"), parent(\"Camera\"), get(\"Cube\",\"y\"))" 2>&1 | tail -1)
# (get gives the local position: the Camera's world y is its own plus the
# Cube's, which has no rotation or scale; 5.3 at the start, moved 2 with it)
want="4 Sphere 3 512 7.3 Cube 3"
fail=0
if [[ "$got" == "$want" ]]; then echo "window -> file -> --eval: ok ($got)"; else echo "window -> file -> --eval: FAILED: got '$got', want '$want'"; fail=1; fi
# save -> open -> save: the same file
"$BIN" --eval "op(\"file.open\", \"$T/z.bee\"); op(\"file.save\", \"$T/z2.bee\")" >/dev/null 2>&1
"$BIN" --eval "op(\"file.open\", \"$T/z2.bee\"); op(\"file.save\", \"$T/z3.bee\")" >/dev/null 2>&1
if [[ -s $T/z2.bee ]] && cmp -s "$T/z2.bee" "$T/z3.bee"; then echo "save -> open -> save: ok (the same file)"; else echo "save -> open -> save: FAILED (the files differ)"; fail=1; fi
# lights and cameras: power, lens
"$BIN" --shot "$T/c.ppm" --click-label row:Light --click-label enum:Point --click-label menuitem:Sun \
  --click-label row:Camera --key enter --type "file.save $T/l.bee" --key enter || exit 1
got=$("$BIN" --eval "op(\"file.open\", \"$T/l.bee\"); print(get(\"Light\",\"power\"), get(\"Camera\",\"lens\"))" 2>&1 | tail -1)
if [[ "$got" == "1 50" ]]; then echo "lights / cameras: ok ($got)"; else echo "lights / cameras: FAILED: got '$got'"; fail=1; fi
"$BIN" --eval "op(\"file.open\", \"$T/l.bee\"); set(\"Light\", \"power\", 3.5); set(\"Camera\", \"lens\", 85); op(\"file.save\", \"$T/l2.bee\")" >/dev/null 2>&1
"$BIN" --shot "$T/d.ppm" --key enter --type "file.open $T/l2.bee" --key enter --type "file.save $T/l3.bee" --key enter || exit 1
got=$("$BIN" --eval "op(\"file.open\", \"$T/l3.bee\"); print(get(\"Light\",\"power\"), get(\"Camera\",\"lens\"))" 2>&1 | tail -1)
if [[ "$got" == "3.5 85" ]]; then echo "--eval -> window -> --eval settings: ok ($got)"; else echo "--eval -> window -> --eval settings: FAILED: got '$got', want '3.5 85'"; fail=1; fi

"$BIN" --eval "op(\"file.save\", \"$T/o.bee\")" >/dev/null 2>&1
"$BIN" --shot "$T/b.ppm" --key enter --type "file.open $T/o.bee" --key enter --dump-ui "$T/b.txt" || fail=1
if grep -q "^toast	Opened o.bee: 3 objects" "$T/b.txt"; then echo "--eval default scene -> window: ok"; else echo "--eval default scene -> window: FAILED"; grep "^toast" "$T/b.txt"; fail=1; fi
# modifiers: a stack saved by one side evaluates to the same mesh in the other, both ways round
"$BIN" --shot "$T/s.ppm" --key enter --type "object.modifier_add mirror" --key enter \
  --type "object.modifier_add subsurf" --key enter --type 'object.modifier_set "1 levels 2"' --key enter \
  --type "object.modifier_add array" --key enter --type 'object.modifier_set "2 count 3"' --key enter \
  --type "object.modifier_add solidify" --key enter --type "file.save $T/s.bee" --key enter --dump-ui "$T/s.txt" || fail=1
got=$("$BIN" --eval "op(\"file.open\", \"$T/s.bee\"); print(modcount(\"Cube\"), efaces(\"Cube\"), everts(\"Cube\"))" 2>&1 | tail -1)
zf=$(grep -oE '[0-9]+ faces' "$T/s.txt" | tail -1 | cut -d' ' -f1)
if [[ "$got" == "4 $zf "* && "$zf" -gt 6 ]]; then echo "modifiers window -> --eval: ok ($got)"; else echo "modifiers window -> --eval: FAILED: got '$got', window $zf faces"; fail=1; fi
"$BIN" --eval "modifier(\"Cube\", \"bevel\"); modset(\"Cube\", 0, \"width\", 0.2); modifier(\"Cube\", \"subsurf\"); modifier(\"Cube\", \"multires\"); op(\"file.save\", \"$T/s2.bee\"); print(efaces(\"Cube\"))" > "$T/s2.out" 2>&1
want=$(tail -1 "$T/s2.out")
"$BIN" --shot "$T/e.ppm" --key enter --type "file.open $T/s2.bee" --key enter --type "file.save $T/s3.bee" --key enter --dump-ui "$T/s3.txt" || fail=1
got=$("$BIN" --eval "op(\"file.open\", \"$T/s3.bee\"); print(modcount(\"Cube\"), efaces(\"Cube\"))" 2>&1 | tail -1)
if [[ "$got" == "3 $want" ]]; then echo "modifiers --eval -> window -> --eval: ok ($got), a Multires kept"; else echo "modifiers --eval -> window -> --eval: FAILED: got '$got', want '3 $want'"; fail=1; fi
# booleans: a modifier and the Edit command, the same faces in the window and after reopening
script='modifier("Cube", "boolean"); modset("Cube", 0, "object", "Sphere"); modset("Cube", 0, "operation", OP);'
for op in 0 1 2; do
  "$BIN" --shot "$T/b$op.ppm" --key enter --type "add sphere" --key enter --type "move 0.7 1.5 0.4" --key enter --key esc \
    --click-label row:Sphere --mods ctrl --click-label row:Cube --mods none \
    --key enter --type "object.modifier_add boolean" --key enter --type "object.modifier_set \"0 operation $op\"" --key enter --type "file.save $T/b$op.bee" --key enter --dump-ui "$T/b$op.txt" || fail=1
  zf=$(grep -oE '[0-9]+ faces' "$T/b$op.txt" | tail -1 | cut -d' ' -f1)
  got=$("$BIN" --eval "op(\"file.open\", \"$T/b$op.bee\"); print(count(), efaces(\"Cube\"))" 2>&1 | tail -1)
  # (the status line sums all: the sphere, 512, is still there)
  if [[ "$got" == "4 $((zf - 512))" && $((zf - 512)) -ne 6 ]]; then echo "boolean modifier $op: ok ($got)"; else echo "boolean modifier $op: FAILED: --eval '$got', window $zf faces"; fail=1; fi
done
"$BIN" --shot "$T/e.ppm" --key enter --type "add sphere" --key enter --type "move 0.7 1.5 0.4" --key enter --key esc \
  --click-label row:Sphere --mods ctrl --click-label row:Cube --mods none --key enter --type "object.boolean difference" --key enter --type "file.save $T/e.bee" --key enter --dump-ui "$T/e.txt" || fail=1
got=$("$BIN" --eval "op(\"file.open\", \"$T/e.bee\"); print(count(), faces(\"Cube\"))" 2>&1 | tail -1)
zf=$(grep -oE '[0-9]+ faces' "$T/e.txt" | tail -1 | cut -d' ' -f1)
if [[ "$got" == "3 $zf" && "$zf" -ne 6 ]]; then echo "boolean command: ok ($got, the sphere used up)"; else echo "boolean command: FAILED: --eval '$got', window $zf"; fail=1; fi
# merge by distance: which target takes a vertex decides the topology; --eval and the window agree
bad=0
for d in 0.3 1 1.3 1.5 2 2.5; do
  o=$("$BIN" --eval "op(\"mode.edit\"); op(\"mesh.subdivide\"); op(\"mesh.subdivide\"); op(\"mesh.merge_distance\", \"$d\"); op(\"mode.object\"); print(verts(\"Cube\"), faces(\"Cube\"))" 2>&1 | tail -1)
  "$BIN" --shot "$T/g.ppm" --dump-ui "$T/g.txt" --move 615,360 --key tab --key enter --type mesh.subdivide --key enter --type mesh.subdivide --key enter --type "mesh.merge_distance $d" --key enter --key esc --move 615,360 --key tab >/dev/null 2>&1
  z=$(grep -E 'info.* v,' "$T/g.txt" | cut -f2 | head -1 | sed -E 's/([0-9]+) v, [0-9]+ e, ([0-9]+) f/\1 \2/')
  [[ "$o" == "$z" && -n "$z" ]] || { echo "merge at $d: --eval '$o', window '$z'"; bad=1; }
done
if [[ $bad == 0 ]]; then echo "merge by distance: ok"; else echo "merge by distance: FAILED"; fail=1; fi
# materials: values, assignments and node graphs (MATS, OMAT, MGRF) come back as they were
"$BIN" --eval "op(\"material.preset\", \"wood\"); op(\"material.new\", \"Glass\"); op(\"material.preset\", \"glass Glass\"); op(\"file.save\", \"$T/m.bee\")" >/dev/null 2>&1
"$BIN" --shot "$T/m.ppm" --key enter --type "file.open $T/m.bee" --key enter --type "material.set Glass roughness 0.125" --key enter --type "file.save $T/m2.bee" --key enter || fail=1
got=$("$BIN" --eval "op(\"file.open\", \"$T/m2.bee\"); print(matof(\"Cube\"), matget(\"wood\",\"roughness\"), matget(\"Glass\",\"transmission\"), matget(\"Glass\",\"roughness\"))" 2>&1 | tail -1)
if [[ "$got" == "Glass 0.55 1 0.125" ]]; then echo "materials --eval -> window -> --eval: ok ($got)"; else echo "materials: FAILED: got '$got', want 'Glass 0.55 1 0.125'"; fail=1; fi
python3 - "$T/m.bee" "$T/m2.bee" <<'PY' || fail=1
import struct, sys
def chunk(p, t):
    d = open(p, 'rb').read(); o = 8
    while o + 8 <= len(d):
        tt, s = struct.unpack_from('<4sI', d, o)
        if tt == t: return d[o + 8:o + 8 + s]
        o += 8 + s
a, b = chunk(sys.argv[1], b'MGRF'), chunk(sys.argv[2], b'MGRF')
if a != b or not a: print("material graphs: FAILED (MGRF differs)"); sys.exit(1)
print("material graphs: ok (%d bytes)" % len(a))
PY
rm -rf "$T"
exit $fail
