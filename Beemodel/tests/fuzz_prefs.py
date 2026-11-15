#!/usr/bin/env python3
"""Random input inside the Preferences dialog: clicks, drags, the wheel,
keys, typing, the categories and their widgets, on a debug build (safety
checks on). The dialog is drawn by Zui (src/zuiprefs.zig). Any crash or
panic is a failure; the command line to replay it is printed.

    BEEMODEL_BIN=zig-out-debug/bin/beemodel tests/fuzz_prefs.py [runs=200] [seed]
"""
import temphome  # noqa: F401 (a HOME of its own)
import os, random, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("BEEMODEL_BIN", os.path.join(os.path.dirname(HERE), "zig-out-debug", "bin", "beemodel"))
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 200
seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
rng = random.Random(seed)

CATS = ["Interface", "Viewport", "Input", "Keymap", "Rendering", "System", "Files", "AI"]
LABELS = ["text:Search settings", "text:Find", "button:Reset to Defaults", "button:Reset All Keys", "button:Set",
          "button:Clear", "button:Theme's", "button:Dark", "button:100 %", "button:BeeModel", "button:Auto",
          "checkbox:Reduce motion", "checkbox:Ground grid", "checkbox:Rendered denoise", "number:Width (px)",
          "number:Samples", "number:Autosave every N changes (0: never)", "colour:Accent", "menuitem:Light",
          "menuitem:150 %", "menuitem:Blender 4.x", "menuitem:CPU", "menuitem:Dracula"]
KEYS = ["tab", "shift+tab", "enter", "up", "down", "left", "right", "home", "end", "backspace", "delete",
        "ctrl+a", "ctrl+c", "ctrl+v", "ctrl+z", "f1", "f8", "g", "x", "1", "minus", "space", "pageup", "pagedown"]
WORDS = ["motion", "undo", "640", "2*3", "wire", "zzz", "é", "-5", "1e9", ""]


def action(w, h):
    k = rng.random()
    # Mostly inside the dialog (centred, about 70 % x 80 %).
    x = rng.randrange(w // 7, w - w // 7)
    y = rng.randrange(h // 10, h - h // 10)
    if k < 0.25:
        return ["--click", f"{x},{y}"]
    if k < 0.32:
        return ["--dbl", f"{x},{y}"]
    if k < 0.38:
        x2, y2 = rng.randrange(w), rng.randrange(h)
        return ["--drag", f"{x},{y},{x2},{y2}"]
    if k < 0.43:
        return ["--wheel", f"{x},{y},{rng.choice([-3, -1, 1, 3])}"]
    if k < 0.55:
        return ["--click-label", "button:" + rng.choice(CATS)]
    if k < 0.70:
        return ["--click-label", rng.choice(LABELS)]
    if k < 0.85:
        return ["--key", rng.choice(KEYS)]
    if k < 0.95:
        return ["--type", rng.choice(WORDS) or "a"]
    return ["--key", "ctrl+comma"]


fails = 0
out = tempfile.mkdtemp(prefix="beefuzzprefs-", dir="/tmp")
for run in range(runs):
    w, h = rng.choice([(1280, 800), (900, 600), (1600, 1000)])
    args = [BIN, "--shot", os.path.join(out, "f.ppm"), "--size", f"{w}x{h}", "--key", "ctrl+comma"]
    for _ in range(rng.randrange(5, 30)):
        args += action(w, h)
    r = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if r.returncode < 0 or "panic" in r.stderr or "reached unreachable" in r.stderr:
        fails += 1
        print("FAIL:", " ".join(repr(a) if " " in a else a for a in args))
        print(r.stderr[-800:])
print(f"seed {seed}: runs {runs}, failures {fails}")
sys.exit(1 if fails else 0)
