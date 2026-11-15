#!/usr/bin/env python3
"""Random-input stability test: many short headless sessions of random
clicks, drags, keys and menu use against a debug build (safety checks on).
Any crash or panic is a failure; its command line is printed to replay it.

    tests/fuzz.py [runs=300] [seed]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, random, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("BEEMODEL_BIN", os.path.join(os.path.dirname(HERE), "zig-out-debug", "bin", "beemodel"))
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 300
seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
rng = random.Random(seed)
KEYS = ["ctrl+tab", "ctrl+tab", "ctrl+d", "ctrl+d", "ctrl+26", "ctrl+27", "26", "27", "shift+26", "shift+27", "c", "k", "l", "p", "alt+m", "shift+c", "shift+t", "shift+s", "g", "r", "s", "x", "y", "z", "a", "h", "alt+h", "shift+d", "shift+a", "ctrl+z", "ctrl+shift+z",
        "f3", "f1", "f6", "shift+f6", "f10", "f2", "esc", "enter", "tab", "delete", "up", "down", "left",
        "right", "home", "kp1", "kp3", "kp7", "kpdot", "tab", "1", "2", "3", "e", "i", "m", "f", "b", "ctrl+x", "shift+n", "alt+e", "ctrl+l", "ctrl+i", "ctrl+space", "ctrl+pagedown", "ctrl+pageup", "alt+v",
        "alt+f", "shift+g", "ctrl+n", "ctrl+s", "ctrl+o", "ctrl+shift+s", "2", "minus", "period", "backspace", "t", "n", "shift+w", "shift+q", "1", "f", "f12", "shift+z", "space", "i", "alt+i", "left", "right", "shift+left", "shift+right"]
LABELS = ["menu:File", "menu:Edit", "menu:View", "menu:Add", "menu:Object", "menuitem:Theme", "menuitem:Cube",
          "menuitem:UV Sphere", "menuitem:Undo", "menuitem:Workspace", "menuitem:Split Area Side by Side",
          "menuitem:Close Area", "menuitem:Float Area", "button:+", "button:Sculpt", "button:Shading", "button:World",
          "editor:3D Viewport", "editor:Outliner", "editor:Console", "row:Cube", "row:Light", "theme:Dracula", "button:Build", "button:Show Clusters",
          "menuitem:Dock Area", "menuitem:New Workspace", "menuitem:Delete Workspace", "command:Dark",
          "menuitem:Preferences...", "colour:Colour", "tab:Viewport", "tab:Scene", "wheel:Material", "wheel:Gold",
          "button:Spot", "button:Sun", "row:Camera", "icon:Overlays", "button:Object Mode", "menuitem:Parent", "menuitem:Clear Parent", "menuitem:Save As...", "menuitem:Open...", "menuitem:Subdivide", "menuitem:Extrude", "menuitem:Dissolve", "menuitem:Fill / Make Face", "button:Edit Mode", "icon:Face Select Mode", "button:Save", "button:Cancel", "button:Don't Save", "column:Size", "file:untitled.bee",
          "tab:Material", "button:New", "button:Preset...", "menuitem:gold", "menuitem:glass", "button:Opaque", "menuitem:Masked",
          "menuitem:None", "colour:Base colour", "colour:Emission", "slider:Roughness", "number:IOR", "checkbox:One-sided",
          "tab:Modifiers", "button:Add Modifier", "menuitem:Mirror", "menuitem:Subdivision Surface", "menuitem:Remesh", "button:Apply", "button:x", "button:^", "button:v", "checkbox:Mirror", "checkbox:Subsurf", "tab:Render", "button:Render (F12)", "button:Settings", "number:Width", "number:Samples", "checkbox:Denoise", "icon:Material Preview", "button:Add Irradiance", "button:Add Reflection", "button:Bake Probes", "button:Remove All", "number:Rays a point", "number:Size (texels)", "button:Clear", "button:Animation", "tab:Animation", "menuitem:Dope Sheet", "menuitem:Graph Editor", "button:Add Shape Key...", "button:New Action...", "button:Add Layer...", "checkbox:Onion skins", "button:Motion Paths", "button:Clear Paths", "checkbox:Mute", "button:Constant", "button:Linear", "button:Bezier", "button:Free", "button:Duplicate", "button:Delete", "icon:Auto-Key", "icon:Play Animation", "icon:Next Frame", "menuitem:Insert Keyframe", "menuitem:Free Handles", "menuitem:Start at This Frame",
          "menuitem:Multiresolution", "button:Subdivide", "button:Propagate", "number:Levels", "number:Level", "number:Detail", "checkbox:Multires",
          "menuitem:Armature", "tab:Rig", "button:Add Constraint...", "button:Parent to Armature...", "row:Bone", "menuitem:Extrude Bone", "menuitem:Delete Bones", "menuitem:Key Pose", "button:Linear blend", "button:Dual quaternion"]


def action(w, h):
    k = rng.random()
    x, y = rng.randrange(w), rng.randrange(h)
    if k < 0.18:
        return ["--click", f"{x},{y}"]
    if k < 0.26:
        return ["--rclick", f"{x},{y}"]
    if k < 0.40:
        return ["--drag", f"{x},{y},{rng.randrange(w)},{rng.randrange(h)}"]
    if k < 0.43:
        return ["--mdrag", f"{x},{y},{rng.randrange(w)},{rng.randrange(h)}"]
    if k < 0.46:
        return ["--wheel", f"{x},{y},{rng.choice([-3, -1, 1, 3])}"]
    if k < 0.50:
        return ["--move", f"{x},{y}"]
    if k < 0.53:
        return ["--dbl", f"{x},{y}"]
    if k < 0.80:
        return ["--key", rng.choice(KEYS)]
    if k < 0.84:
        return ["--type", rng.choice(["add cube", "theme nord", "2*pi", "help", "undo", "file.new", "list", "1.5",
            "material.new", "material.new \"My Mat\"", "material.preset emissive", "material.set Material base 0.2 nan 9",
            "material.set Material roughness -1", "material.remove Material", "material.assign none", "material.assign Material",
            "material.apply_preset wood", "material.set gold blend 2", "render.settings 64 36 4",
            "create.cone", "create.torus", "create.grid", "create.ground", "create.ground height 3", "view.show_normals", "view.show_boundary", "view.show_nonmanifold", "view.show_degenerate", "view.show_overhangs", "view.show_overhangs 30", "view.show_overhangs nan", "edit.redo_last 0.2", "edit.redo_last 3 40 z", "edit.redo_last nan", "edit.redo_prompt", "mesh.inset 0.1", "mesh.extrude 1", "mesh.extrude_individual 0.5", "mesh.bevel \"0.1 2\"", "mesh.spin \"4 90 y\"", "mesh.merge_distance 0.2", "file.recover", "view.screenshot /tmp/beemodel-headless/s.png", "workspace.new", "workspace.new Mine", "workspace.set Sculpt", "workspace.set 3", "workspace.set nothing", "workspace.rename X", "file.export_obj /tmp/beemodel-headless/f.obj", "file.import_obj /tmp/beemodel-headless/f.obj", "file.export_stl /tmp/beemodel-headless/f.stl", "file.save /tmp/beemodel-headless/w.bee", "file.open /tmp/beemodel-headless/w.bee",
            "render.pass", "render.pass depth", "view.shading_rendered", "object.boolean union keep", "object.boolean difference", "object.boolean intersect", "object.modifier_add subsurf", "object.modifier_add mirror", "object.modifier_add solidify", "object.modifier_add decimate", "object.modifier_add bevel", "object.modifier_add array", "object.modifier_add boolean", "object.modifier_apply", "object.modifier_remove", "object.modifier_toggle", "object.modifier_move_down", 'object.modifier_set "0 levels 3"', 'object.modifier_set "0 count 50"', "world.hdri none", "world.strength 3", "world.rotation 45", "view.rendered_samples 4", "view.rendered_samples 0", "view.rendered_denoise", "view.shading_solid", "render.denoise", "render.settings 0 -5 nan", "render.stop", "view.toggle_material_preview", "probe.add irradiance", "probe.add reflection 0 1 0 2 2 2", "probe.add irradiance 0 nan inf 1e39 0 -1 99 0 2", "probe.bake 16", "probe.remove 1", "probe.remove 99", "probe.clear", "lightmap.bake 64 2", "lightmap.bake 0 -1", "lightmap.save /tmp/beemodel-headless/l.png", "lightmap.save /tmp/beemodel-headless/l.exr", "lightmap.clear",
            "file.open tests/files/tex_uv.bee", "material.node Material noise 4", "material.node Material nosuch", "material.node Material math 99 nan", "material.link Material 1 2 1", "material.link Material 2 1 3 9", "material.socket Material base 1", "material.socket Material normal 2", "material.socket Material nosuch 1", "material.node_set Material 1 2 nan", "material.node_set Material 99 9 1", "material.node_delete Material 1", "material.nodes_clear Material", "material.instance Material", "material.param Material Param 0.5", "material.param_reset Material_Inst Param", "material.function_new", "material.texture Material none", "material.import_textures tests/files/oracle_tex.png", "material.import_textures /nonexistent/x.png", "material.bake Cube 16", "material.bake Cube 16 apply", "material.bake Cube 0", "object.bake Cube Cube ao M_base", "object.bake Cube Cube normal nosuch", "object.bake Nothing Cube curvature x", "object.bake Cube Cube normal fz nan", "paint.undo", "paint.redo", "uv.unwrap", "uv.smart_project", "uv.pack", "uv.seam_mark", "uv.seam_clear", "uv.seams_from_sharp", "area.type_uv_editor", "uv.select_all", "uv.grab", "uv.scale", "uv.rotate", "uv.heat_map", "uv.view_fit", "image.new fz 8 8", "material.preset marble", "material.preset leather",
            "object.add_reference tests/files/reference.png", "object.add_reference /tmp/beemodel-headless/nothing.png", "object.add_references tests/files", "object.add_references /nonexistent", "object.reference_pin Reference 1 2 3 4 5", "object.reference_pin Reference nan 1e39 0 0 0", "object.reference_kind Reference plan 2 30", "object.reference_kind Reference left", "object.reference_kind Nothing other", "anim.range 5 9 30", "anim.range 9 5", "anim.range nan inf", "anim.range -100000 100000 0", "vgeo.build", "vgeo.build", "vgeo.build async", "vgeo.clear", "vgeo.proxy", "vgeo.extract", "vgeo.extract 1", "vgeo.extract 99", "vgeo.extract 0.01", "vgeo.extract nan", "vgeo.error 0.5", "vgeo.error 16", "vgeo.error nan", "vgeo.error -3", "vgeo.budget 1", "vgeo.budget nan", "vgeo.view clusters", "vgeo.view off", "vgeo.view shaded", "vgeo.view check", "vgeo.view stats", "vgeo.view info", "vgeo.view", "render.animation /tmp/beemodel-headless/fz.apng 1 2", "render.animation /tmp/beemodel-headless/fzd 3 2",
            "anim.key Cube:x 1 0", "anim.key Cube:x 30 5", "anim.key Cube:y 12 nan linear", "anim.key Cube:rz 60 1e30", "anim.key Nothing:x", "anim.key material:Material:roughness 1 0.2", "anim.key material:Material:base:1 40 0.8 constant", "anim.key modifier:Cube:0:levels 1 3", "anim.unkey Cube:x 1", "anim.frame 15", "anim.frame 2.5", "anim.frame -1e30", "anim.frame 1e30", "anim.frame nan", "anim.play", "anim.next_frame", "anim.prev_frame", "anim.first_frame", "anim.last_frame", "anim.insert_key", "anim.delete_key", "anim.interpolation linear", "anim.interpolation constant", "anim.select_keys all", "anim.select_keys none", "anim.select_keys frame 30", "anim.select_keys Cube:x 30 extend", "anim.move_keys 5", "anim.move_keys -3 1e30", "anim.scale_keys 2", "anim.scale_keys 0", "anim.scale_keys nan", "anim.delete_keys", "anim.duplicate_keys 7", "anim.handle_type free", "anim.handle_type auto", "anim.handle Cube:x 30 right 3 1", "anim.action Act", "anim.layer Act", "anim.layer Act Cube 5 0.5 add 2", "anim.layer_set 1 influence 0.5", "anim.layer_set 1 repeat 0", "anim.layer_set 99 mute 1", "anim.layer_remove 1", "anim.driver Cube:y a=Cube:x a*2", "anim.driver Cube:x a=Cube:x a+1", "anim.driver Cube:z frame/0", "anim.driver Cube:rz sin(frame/5)", "anim.driver_set 1 mute 1", "anim.driver_set 1 expression nonsense(", "anim.driver_set 1 remove", "anim.driver_remove Cube:y", "anim.motion_paths", "anim.motion_paths 1 1000000", "anim.motion_paths clear", "anim.onion", "anim.onion 2 2 1", "anim.onion 99 99 0", "anim.onion off", "anim.auto_key", "shape.add Smile", "shape.add Smile Cube", "shape.set Smile 0.5", "shape.set Smile nan", "shape.edit Smile", "shape.remove Smile", "shape.remove Basis", "shape.clear", "area.type_dope_sheet", "area.type_graph_editor", "area.type_timeline", "area.type_viewport",
            "object.texture_paint", "object.vertex_paint", "object.weight_paint", "mode.texture_paint", "mode.vertex_paint", "mode.weight_paint", "paint.color 1 2 3", "paint.color 999 x", "paint.weight nan", "paint.weight 0.3", "paint.layer_add", "paint.layer_up", "paint.layer_down", "paint.layer_merge", "layer Bake add", "layer Bake opacity 1 nan", "layer Bake remove 1", "paint Cube 0 1 1 1 9 9 9", "vpaint Cube 0 1 1 1 9 9 9", "wpaint Cube 0 1 1 1 0 1", "object.sculpt_mode", "mode.sculpt", "mode.object", "sculpt.dyntopo", "sculpt.detail_finer", "sculpt.detail_coarser", "object.modifier_add multires", "multires.propagate_down", 'object.modifier_set "0 level 2"', 'object.modifier_set "0 level 0"', 'object.modifier_set "0 levels 6"', "sculpt.symmetry xyz", "sculpt.symmetry none", "sculpt.falloff root", "sculpt.falloff nosuch", "sculpt.mask_invert", "sculpt.mask_clear", "sculpt.stabilizer", "sculpt.pressure_curve", "sculpt.pressure_radius", "sculpt.info", 'sculpt Cube draw 0 1 1 0.2 1 1 1 0.5', 'sculpt Cube "snake hook" 0 1 1 0.2 1 1 1 0.5', 'sculpt Cube grab 0 1 1 0.2 1 1 1 0.5', 'sculpt Cube smooth 0 1 1 0.2 1 1 1e30 1', 'sculpt Cube mask 0 0 0 0 0 0 9 1'])]
    if k < 0.97:
        return ["--click-label", rng.choice(LABELS)]
    if rng.random() < 0.3:
        return ["--live-wait"]
    return ["--wait", "700"]


fails = 0
tmp = tempfile.mkdtemp()
for r in range(runs):
    w, h = rng.choice([(1280, 800), (900, 600), (640, 420), (1920, 1080), (500, 360)])
    cmd = [BIN, "--shot", os.path.join(tmp, "f.ppm"), "--size", f"{w}x{h}"]
    for _ in range(rng.randrange(4, 40)):
        cmd += action(w, h)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode not in (0, 2):
        fails += 1
        print("FAIL rc=%d: %s" % (p.returncode, " ".join("'%s'" % c if " " in c else c for c in cmd)))
        print("\n".join(p.stderr.splitlines()[-12:]))
print("seed %d: runs %d, failures %d" % (seed, runs, fails))
sys.exit(1 if fails else 0)
