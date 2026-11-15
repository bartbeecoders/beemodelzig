#!/usr/bin/env python3
"""Edit-mode fuzzing: random chains of mesh tools, selections, transforms,
undo / redo on random primitives (debug build).   tests/fuzz_edit.py BIN RUNS SEED"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, random, subprocess, sys, tempfile
BIN = sys.argv[1]; runs = int(sys.argv[2]); seed = int(sys.argv[3]); rng = random.Random(seed)
KEYS = ["1", "2", "3", "a", "ctrl+i", "ctrl+l", "x", "delete", "m", "f", "shift+n", "ctrl+x", "ctrl+z",
        "ctrl+shift+z", "z", "kpdot", "tab"]
TOOLS = [["--key", "e", "--type", "0.7", "--key", "enter"], ["--key", "e", "--move", "700,300", "--key", "esc"],
         ["--key", "i", "--type", "0.2", "--key", "enter"], ["--key", "alt+e", "--type", "0.4", "--key", "enter"],
         ["--key", "g", "--key", "y", "--type", "0.5", "--key", "enter"], ["--key", "r", "--key", "z", "--type", "30", "--key", "enter"],
         ["--key", "s", "--type", "1.2", "--key", "enter"], ["--key", "shift+d", "--key", "x", "--type", "1", "--key", "enter"],
         ["--click-label", "menu:Mesh", "--click-label", "menuitem:Subdivide"],
         ["--click-label", "menu:Mesh", "--move-label", "menuitem:Normals", "--click-label", "menuitem:Flip Normals"],
         ["--key", "b", "--drag", "500,250,760,420"], ["--mods", "alt", "--click", "620,330", "--mods", "none"],
         ["--mods", "shift", "--click", "640,300", "--mods", "none"],
         ["--key", "ctrl+r", "--move", "615,350", "--wheel", "615,350,-1", "--click", "615,350"],
         ["--click-label", "menu:Mesh", "--click-label", "menuitem:Bridge Edge Loops"],
         ["--click-label", "menu:Edit", "--click-label", "menuitem:Repair Mesh"],
         ["--key", "ctrl+b", "--move", "680,360", "--wheel", "680,360,-1", "--move", "700,360", "--click", "700,360"],
         ["--key", "ctrl+b", "--type", "0.2", "--key", "enter"], ["--key", "ctrl+b", "--move", "720,360", "--key", "esc"],
         ["--click-label", "menu:Mesh", "--click-label", "menuitem:Bisect"],
         ["--click-label", "menu:Mesh", "--click-label", "menuitem:Spin"],
         ["--key", "g", "--move", "700,330", "--move", "760,300", "--rclick", "760,300"],
         ["--rclick", "615,360", "--key", "8", "--key", "1"],
         ["--key", "k", "--click", "560,250", "--click", "700,420", "--key", "enter"],
         ["--key", "k", "--click", "500,300", "--click", "620,330", "--click", "760,300", "--key", "backspace", "--key", "enter"],
         ["--key", "k", "--click", "600,300", "--key", "esc"]]
PRIMS = ["Cube", "UV Sphere", "Cylinder", "Plane"]
fails = 0
tmp = tempfile.mkdtemp()
for r in range(runs):
    cmd = [BIN, "--shot", os.path.join(tmp, "e.ppm"), "--move", "615,360"]
    if rng.random() < 0.6:
        cmd += ["--key", "x", "--shift-key", "a", "--click-label", "menuitem:" + rng.choice(PRIMS), "--move", "615,360"]
    cmd += ["--key", "tab"]
    for _ in range(rng.randrange(3, 30)):
        k = rng.random()
        if k < 0.35:
            cmd += ["--key", rng.choice(KEYS)]
        elif k < 0.75:
            cmd += rng.choice(TOOLS)
        else:
            cmd += ["--click", f"{rng.randrange(400, 840)},{rng.randrange(150, 470)}"]
        cmd += ["--move", "615,360"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode not in (0, 2):
        fails += 1
        print("FAIL rc=%d: %s" % (p.returncode, " ".join("'%s'" % c if " " in c else c for c in cmd)))
        print("\n".join(p.stderr.splitlines()[-14:]))
print("runs", runs, "fails", fails)
sys.exit(1 if fails else 0)
