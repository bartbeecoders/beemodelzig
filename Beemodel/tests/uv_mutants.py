#!/usr/bin/env python3
"""Each guard of tests/uv.py shown failing: the code it guards broken, one thing at
a time, in a copy of the sources; that part of the suite must then fail. A mutant
that survives is a test that passes on nothing. (Since 2026-11-14 tests/uv.py
runs standalone: the mutants it could only catch by comparing numbers with the
original are gone; these are the ones its own checks catch.)

    python3 tests/uv_mutants.py WORKDIR [jobs=12] [name...]   (WORKDIR under /tmp: headless saves go nowhere else)
"""
import concurrent.futures, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig as the project pins it, asked before the temp HOME hides mise's installs:
# its shim knows no version in WORKDIR)
try:
    ZIG = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT, capture_output=True, text=True).stdout.strip() or 'zig'
except OSError:
    ZIG = 'zig'
import temphome  # noqa: F401,E402 (a HOME of its own: the user's ~/.config stays as it is)

W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
M = [  # name, file, old, new, the scenarios that must fail
    # --- unwrap: islands, seams, the scripts
    ('lscm: seams not seams', 'src/uv.zig', 'if (tw == NONE or isSeam(me, l, tw)) continue;', '_ = me;\n        if (tw == NONE) continue;', 's_same'),
    ('a UV vertex does not join across its edge', 'src/uv.zig', 'smartuv.join(luv, t.next[l], tw);', '', 's_same'),
    ('islands: not by the bits', 'src/smartuv.zig', 'return @as(u32, @bitCast(a[0])) == @as(u32, @bitCast(b[0])) and @as(u32, @bitCast(a[1])) == @as(u32, @bitCast(b[1]));', 'return @abs(a[0] - b[0]) < 0.3 and @abs(a[1] - b[1]) < 0.3;', 's_same'),
    # --- seams
    ('seams: clear marks', 'src/uv.zig', 'me.seam[l] = @intFromBool(mode == .mark);', 'me.seam[l] = 1;', 's_seams'),
    ('seams: not drawn', 'src/viewport.zig', '    if (em.active) drawSeams(cv, &c);\n', '', 's_seams'),
    # --- measures
    ('stat: flipped the other way', 'src/uv.zig', 'if (!(area2(&u) >= 0)) sum += 1;', 'if (area2(&u) > 0) sum += 1;', 's_stats'),
    ('stat: overlap counts once', 'src/uv.zig', 'if (c > 1) twice += 1;', 'if (c > 0) twice += 1;', 's_stats'),
    ('stat: inside looks at u', 'src/uv.zig', 'if (!(c >= 0 and c <= 1)) return 0;', 'if (!(c >= 0)) return 0;', 's_stats'),
    # --- the file
    ('MUVS not written', 'src/bee.zig', 'if (ix != 0xffffffff) writeUvs(&b, ix, &scene.meshes[mi].?);', '_ = ix;\n        _ = mi;', 's_files'),
    ('MUVS: seam bytes not padded', 'src/bee.zig', 'b.bytes(zero[0 .. (4 - me.seam.len % 4) % 4]);', '_ = zero;', 's_files'),
    ('MUVS: seams not read', 'src/bee.zig', 'me.seam = al.dupe(u8, s) catch &.{};', '_ = s;', 's_files'),
    ('MUVS: damaged: no size check', 'src/bee.zig', 'if (size > c.len - o - 12) return false;', '', 's_damage'),
    ('MUVS: damaged: NaN kept', 'src/bee.zig', '// (a file is not to be trusted)\n                    for (u) |*x| {\n                        if (!std.math.isFinite(x.*)) x.* = 0;', '// (a file is not to be trusted)\n                    for (u) |*x| {\n                        _ = x;', 's_damage'),
    # --- undo
    ('undo: UVs in place', 'src/uv.zig', 'const c = scene.cloneMesh(mi) orelse return null;\n    const vs', 'const c = mi;\n    const vs', 's_undo_steps'),
    ('undo: a transform in place', 'src/uved.zig', 'const me = uv.cow(t.oi) orelse return;', 'const me = &scene.meshes[scene.objects[t.oi].mesh.?].?;', 's_undo'),
    ('undo: cancel keeps the UVs', 'src/uved.zig', 'if (back) @memcpy(me.uv, orig) else app.log("  uv: islands transformed", .{});', 'if (!back) app.log("  uv: islands transformed", .{});', 's_undo'),
    ('undo: cancel leaves no step', 'src/uved.zig', 'if (back) @memcpy(me.uv, orig) else app.log("  uv: islands transformed", .{});', 'if (back) {\n        scene.objects[tm_oi].mesh = undo_old;\n        return;\n    }', 's_undo_steps'),
    ('undo: nothing selected still a step', 'src/uved.zig', 'if (std.mem.indexOfNone(u8, s, &.{0}) == null) return; // (nothing to transform)', '', 's_undo_steps'),
    ('undo: a no-op makes no step', 'src/uv.zig', 'const me = cow(oi) orelse return none();\n    undo.label("Pack Islands");\n    report(pack(me));', 'if (scene.meshOfObj(oi).?.uv.len == 0) return app.log("  uv: out of memory", .{});\n    const me = cow(oi) orelse return none();\n    undo.label("Pack Islands");\n    report(pack(me));', 's_undo_steps'),
    ('undo: the wrong label', 'src/uv.zig', 'undo.label("Pack Islands");', 'undo.label("Unwrap");', 's_undo_steps'),
    # --- the editor
    ('editor: scale floor', 'src/uved.zig', 'const la = @max(@sqrt(ax * ax + ay * ay), 1.0);', 'const la = @max(@sqrt(ax * ax + ay * ay), 100.0);', 's_transforms'),
    ('editor: shift does not add', 'src/uved.zig', 'if (!ui.shift()) @memset(s, 0);', '@memset(s, 0);', 's_transforms'),
    ('editor: a click on nothing keeps', 'src/uved.zig', 'if (!ui.shift()) @memset(s, 0);', '', 's_transforms'),
    ('editor: a press keeps whatever the button', 'src/uved.zig', 'end(button != wl.BTN_LEFT);', '_ = button;\n    end(false);', 's_undo'),
    ('editor: the press goes on to the island', 'src/app.zig', 'ue.press(b.button);\n                    ui.active = 0x7fffffff;', 'ue.press(b.button);\n                    ui.pressed = bit;\n                    hitPass(cv);\n                    ui.pressed = 0;', 's_transforms'),
    ('editor: Enter not taken', 'src/uved.zig', ' else if (k == ui.KEY.ENTER) end(false);', ';', 's_undo'),
    ('editor: lit edges not lit', 'src/uved.zig', 'if (s != null and s.?[l] != 0) COL_SEL else edge', 'if (s != null and s.?[l] == 200) COL_SEL else edge', 's_look'),
    ('editor: Home keeps the zoom', 'src/uved.zig', 'cy = 0.5;\n    zoomf = 1;', 'cy = 0.5;', 's_look'),
    ('the viewport keeps the old UVs', 'src/viewport.zig', 'if (scene.meshes[mi]) |*me| h.update(std.mem.asBytes(&me.serial));', '_ = mi;', 's_preview'),
    ('a cancel leaves the drag in the caches', 'src/uved.zig', '    scene.meshes_made +%= 1;\n    me.serial = scene.meshes_made;\n', '', 's_preview'),
    # --- keys, greyed, the area
    ('keys: not only over the editor', 'src/ops.zig', 'const over_uv = app.hoverEditor() == .uved;', 'const over_uv = true;', 's_ui'),
    ('poll: Unwrap in object mode', 'src/uv.zig', 'if (ops.scripted or em.active) return null;', 'if (true) return null;', 's_ui'),
    ('poll: scripts refused', 'src/uv.zig', 'if (ops.scripted or em.active) return null;', 'if (em.active) return null;', 's_same'),
    ('Tab only over a viewport', 'src/ops.zig', 'if (im.ctx == .view3d and !over_view3d and !over_uv) continue;', 'if (im.ctx == .view3d and !over_view3d) continue;', 's_keys'),
    ('no message for a light', 'src/uv.zig', 'app.log("  uv: select a mesh", .{});', '', 's_undo_steps'),
    ('the heat list does not set', 'src/uved.zig', 'heat = @intCast(k);\n', '_ = k;\n', 's_ui'),
    ('idle: the editor keeps drawing', 'src/main.zig', 'app.frameDrawn();\n                app.dirty = false;', 'app.frameDrawn();\n                app.dirty = @import("uved.zig").heat != 0;', 's_idle'),
    # --- degenerate
    ('a line of a million pixels', 'src/uved.zig', 'const lim = 16384;', 'const lim = 2000000000;', 's_degenerate'),
    ('heat: NaN to an int', 'src/uved.zig', 'if (!(x > -2.0e9 and x < 2.0e9)) return std.math.minInt(i32);\n            return @intFromFloat(x);', 'return @intFromFloat(x);', 's_degenerate'),
    ('a pixel from any float', 'src/uved.zig', 'if (std.math.isNan(x)) return 0;\n    const c = std.math.clamp(x, -1.0e9, 1.0e9);', 'const c = x;', 's_degenerate'),
    # --- baking
    ('bake: no step', 'src/bake.zig', 'if (before) |b| pthist.commit(im, b);', '_ = before;', 's_bake'),
    ('bake: a step for what was undone kept', 'src/pthist.zig', 'while (hn > hpos) {\n        hn -= 1;\n        A.free(hist[hn].px);\n    }', '', 's_bake'),
    ('bake: undo does not swap', 'src/pthist.zig', 'for (e.b8, s.px) |*a, *b| std.mem.swap([4]u8, a, b);', 'for (e.b8, s.px) |*a, *b| a.* = b.*;', 's_bake'),
    ('bake: the form asks for normal whatever', 'src/forms.zig', '.words = &.{ "normal", "ao", "curvature" }', '.words = &.{ "normal", "normal", "normal" }', 's_bake'),
    ('bake: no form', 'src/forms.zig', '.{ .op = "object.bake", .fields', '.{ .op = "object.bakx", .fields', 's_bake'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon names ../BeeZigUi: one next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        if os.path.isdir(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        if name == 'undo: cancel leaves no step':
            # (the object goes back to the mesh it had)
            t = t.replace('tm_oi = t.oi;\n', 'tm_oi = t.oi;\n    undo_old = t_old;\n').replace('const me = uv.cow(t.oi) orelse return;', 'const t_old = scene.objects[t.oi].mesh;\n    const me = uv.cow(t.oi) orelse return;').replace('var tm_oi: usize = 0;', 'var tm_oi: usize = 0;\nvar undo_old: ?u16 = null;')
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, UV_ONLY=scen, BEEUV_TMP=d)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/uv.py', f'{d}/out/bin/beemodel', '25', '4242'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:90]}' if fails else f'nothing in {scen} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
