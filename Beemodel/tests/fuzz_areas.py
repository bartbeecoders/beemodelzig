"""Area / panel / workspace heavy fuzzing at small window sizes (found the
splitter clamp crash).  tests/fuzz_areas.py BIN RUNS SEED"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import random, subprocess, sys, os, tempfile
BIN=sys.argv[1]; runs=int(sys.argv[2]); seed=int(sys.argv[3]); rng=random.Random(seed)
L=["menuitem:Dope Sheet","menuitem:Graph Editor","menuitem:Timeline","editor:Dope Sheet","editor:Graph Editor","editor:Timeline","button:Animation","tab:Animation","menuitem:Float Area","menuitem:Dock Area","menuitem:Close Area","menuitem:Maximize Area","menuitem:Split Area Side by Side","menuitem:Split Area Top/Bottom","menuitem:Open in New Window",
 "icon:area.close","icon:area.maximize","icon:area.split_side","icon:area.split_stack","button:+","button:Sculpt","button:World","button:Modeling","menuitem:Delete Workspace","menuitem:New Workspace",
 "menuitem:Rename Workspace","menuitem:Next Workspace","menuitem:Duplicate","menuitem:Delete","menuitem:Undo","menuitem:Redo","menuitem:Tools Pane","menuitem:Outliner Pane","menuitem:Console Pane",
 "row:Cube","row:Camera","editor:Outliner","editor:3D Viewport","editor:Properties","editor:Console","menu:View","menu:Object","menu:Edit","menuitem:Workspace","menuitem:Theme","menuitem:Dracula","menuitem:Light"]
K=["i","space","left","right","g","r","s","x","y","z","shift+d","ctrl+z","ctrl+shift+z","f6","shift+f6","t","n","ctrl+pagedown","ctrl+pageup","esc","enter","delete","a","h","alt+h","f3","f1","f10","down","up","right","left","ctrl+space","2","minus","backspace","shift+a","alt+v","alt+o","f2","tab","home","kpdot"]
fails=0
for r in range(runs):
    w,h=rng.choice([(1280,800),(640,420),(400,300),(300,200),(160,120),(800,250),(250,800)])
    cmd=[BIN,"--shot",os.path.join(tempfile.gettempdir(), "beemodel-nasty.ppm"),"--size",f"{w}x{h}"]
    for _ in range(rng.randrange(10,60)):
        k=rng.random(); x,y=rng.randrange(w),rng.randrange(h)
        if k<0.3: cmd+=[rng.choice(["--click-label","--rclick-label","--dbl-label","--move-label"]),rng.choice(L)]
        elif k<0.6: cmd+=["--key",rng.choice(K)]
        elif k<0.7: cmd+=["--rclick",f"{x},{min(h-1,rng.choice([62,70,y]))}"]
        elif k<0.85: cmd+=["--drag",f"{x},{rng.choice([60,62,70,y])},{rng.randrange(w)},{rng.randrange(h)}"]
        elif k<0.9: cmd+=["--type",rng.choice(["anim.key Cube:x 1 0","anim.key Cube:x 30 4","area.type_dope_sheet","area.type_graph_editor","add cube","2*pi","xx","theme light","delete","1.5"])]
        elif k<0.95: cmd+=["--click",f"{x},{y}"]
        else: cmd+=["--wheel",f"{x},{y},{rng.choice([-5,5])}"]
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
    if p.returncode not in (0,2):
        fails+=1; print("FAIL rc=%d: %s"%(p.returncode," ".join("'%s'"%c if " " in c else c for c in cmd))); print("\n".join(p.stderr.splitlines()[-25:])); sys.stdout.flush()
print("runs",runs,"fails",fails)
