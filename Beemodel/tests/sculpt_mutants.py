#!/usr/bin/env python3
"""Each guard of tests/sculpt.py shown failing: the code it guards broken, one thing at
a time, in a copy of the sources; that part of the suite must then fail. A mutant
that survives is a test that passes on nothing.

(Only mutants a standalone check can see: ones caught only by a vertex-for-vertex
match with the original, or by the pen, are gone.)

    python3 tests/sculpt_mutants.py WORKDIR [name...]   (each builds: minutes)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# (a copy builds outside the repo: build.zig.zon's ../BeeZigUi must be beside
# it, and zig itself on PATH: mise's shim needs the repo's mise.toml)
def ui_link(build_root):
    """BeeZigUi beside a copy's build root, as build.zig.zon wants it."""
    link = os.path.join(os.path.dirname(os.path.abspath(build_root)), 'BeeZigUi')
    if not os.path.exists(link):
        os.symlink(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), link)


import pwd as _pwd  # noqa: E402
_ZIG = os.path.join(_pwd.getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG) and _ZIG not in os.environ.get('PATH', ''):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the scenarios that must fail
    ('stabilizer: no string', 'src/stroke.zig', 'if (!(d > len)) return null;', 'if (d > 1e9) return null;', 's_window'),
    ('falloff: root is sharp', 'src/sculpt.zig', '2 => @sqrt(a),', '2 => a * a,', 's_falloff'),
    ('falloff: mask ignored', 'src/sculpt.zig', 'if (k != 0) w = w * (1.0 - @as(f32, @floatFromInt(k)) * sf_mask);', 'if (k != 0 and w < 0) w = w * (1.0 - @as(f32, @floatFromInt(k)) * sf_mask);', 's_mask'),
    ('mask: invert clears', 'src/sculpt.zig', 'x.* ^= 255;', 'x.* = 0;', 's_mask'),
    ('symmetry: combinations lost', 'src/sculpt.zig', 'if (~sym & k != 0) continue; // (a mirror', 'if (k != sym) continue; // (a mirror', 's_falloff'),
    ('matrix: not followed', 'src/sculpt.zig', 'const p0 = arm.xformPoint(&sc_mi, from); // the ends, local', 'const p0 = from;', 's_objects'),
    ('undo: stroke not put back', 'src/undo.zig', 'if (deltas[s]) |d| d.apply(d.ctx, true);\n    cur -= 1;', 'cur -= 1;', 's_undo'),
    ('redo: stroke not redone', 'src/undo.zig', 'scene.load(&states[s]);\n    if (deltas[s]) |d| d.apply(d.ctx, false);', 'scene.load(&states[s]);', 's_undo'),
    ('undo: delta with no new', 'src/sculpt.zig', 'const src = if (back) old else old + h.n;', 'const src = if (back) old else old;', 's_undo'),
    ('history: jumps past the strokes', 'src/undo.zig', 'if (deltas[slot(cur)]) |d| d.apply(d.ctx, true);\n    }', '}', 's_undo'),
    ('undo: no budget for strokes', 'src/undo.zig', 'if (deltas[slot(k)]) |d| bytes += d.bytes;\n', '', 's_delta'),
    ('undo: redo steps not dropped', 'src/undo.zig', '    while (k < len) : (k += 1) dropDelta(slot(k));\n    len = cur + 1;', '    while (k < len) : (k += 1) dropDelta(slot(k));\n    if (k > 1000) len = cur + 1;', 's_undo'),
    ('undo: boxes after an undo stale', 'src/sculpt.zig', '        refresh_due = true;\n', '', 's_undo_window'),
    ('undo: a stroke per dab', 'src/sculpt.zig', '    dab(r);\n    if (ext.after_dab) |g| g(r, 0);', '    dab(r);\n    if (stroking) strokeEnd();\n    stroking = true;\n    if (ext.after_dab) |g| g(r, 0);', 's_undo'),
    ('undo: stroke in the way', 'src/undo.zig', 'return cur > 0 or @import("sculpt.zig").stroking;', 'return cur > 0;', 's_midstroke'),
    ('leaving: the stroke lost', 'src/sculpt.zig', '    } else {\n        finishStroke();\n', '    } else {\n', 's_midstroke'),
    ('shared: a primitive sculpted', 'src/sculpt.zig', 'for (scene.prim) |p| {\n        if (p == mi) return true;\n    }\n', '', 's_shared'),
    ('shared: a duplicate sculpted', 'src/sculpt.zig', 'if (k != i and o.mesh == mi) return true;', 'if (k != i and o.mesh == mi and false) return true;', 's_shared'),
    ('shared: copy not in the step', 'src/sculpt.zig', 'undo.absorbMesh(i); // (the copy', '// (the copy', 's_shared'),
    ('shared: only on entering', 'src/sculpt.zig', 'if (!ownMesh(obj) or !valid()) return false;', '', 's_shared'),
    ('caches: stale after a stroke', 'src/sculpt.zig', 'if (mesh_mi) |mi| scene.bumpShape(mi); // (caches keyed by it)', '', 's_evaluated'),
    ('caches: stale after an undo', 'src/sculpt.zig', '    scene.refreshMesh(mi);\n    if (on and mesh_mi == mi', '    if (on and mesh_mi == mi', 's_evaluated'),
    ('picture: every tile, every frame', 'src/sculptdraw.zig', 'if (!sdc_valid or sc.full or !sc.stroking) return;', 'if (true) return;', 's_ui'),
    ('picture: every leaf, every frame', 'src/sculptdraw.zig', 'if (chg == 0 and !sc.full) continue;', 'if (chg == 7 and !sc.full) continue;', 's_ui'),
    ('picture: tiles of the old place missed', 'src/sculptdraw.zig', '        markTiles(&sdc_prev[l]); // where it was\n', '', 's_ui'),
    ('grab: the region shrinks on the way back', 'src/sculpt.zig', 'grab_far = maxss(grab_far, @sqrt(d2));', 'grab_far = @sqrt(d2);', 's_ui'),
    ('idle: a frame for ever', 'src/main.zig', 'app.frameDrawn();\n                app.dirty = false;', 'app.frameDrawn();\n                app.dirty = @import("sculpt.zig").on;', 's_idle'),
    ('keys: Shift+S the pie', 'src/pies.zig', 'code == K.S and md == wl.MOD_SHIFT and !@import("sculpt.zig").on', 'code == K.S and md == wl.MOD_SHIFT', 's_ui'),
    ('keys: everywhere', 'src/ops.zig', 'if (im.mode == .arm or im.mode == .sculpt) continue;', 'if (im.mode == .arm) continue;', 's_ui'),
    ('keys: radius unbounded', 'src/sculptui.zig', 'sc.radius = stroke.minss(stroke.maxss(sc.radius * k, sf_rmin), sf_rmax);', 'sc.radius = sc.radius * k;', 's_ui'),
    ('damaged: lopsided', 'src/sculpt.zig', 'if (nnodes == nodes.len) {', 'if (false) {', 's_robust'),
    ('damaged: NaN indexing', 'src/stroke.zig', '''pub inline fn trunc32(x: f32) i32 {
    return asm ("cvttss2si %[x], %[r]"
        : [r] "=r" (-> i32),
        : [x] "x" (x),
    );
}''', '''pub inline fn trunc32(x: f32) i32 {
    return @intFromFloat(x);
}''', 's_robust'),
    ('undo: the whole mesh', 'src/sculpt.zig', 'const bytes = @sizeOf(Block) + @as(usize, n) * 28;', 'const bytes = @sizeOf(Block) + @as(usize, n) * 28 + @as(usize, nv) * 12;', 's_delta'),
]
want = sys.argv[2:]
src = f'{W}/src'
survivors = []
for name, fn, old, new, scen in M:
    if want and name not in want:
        continue
    if not os.path.exists(f'{src}/build.zig'):
        os.makedirs(src, exist_ok=True)
        shutil.copytree(f'{ROOT}/src', f'{src}/src')
        shutil.copy(f'{ROOT}/build.zig', src)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', src)
    for x in os.listdir(f'{ROOT}/src'):
        if x.endswith('.zig'):
            q = f'{src}/src/{x}'
            t = open(f'{ROOT}/src/{x}').read()
            if not os.path.exists(q) or open(q).read() != t:
                open(q, 'w').write(t)
    p = f'{src}/{fn}'
    t = open(p).read()
    if old not in t:
        print(f'  ?    {name}: the code is not there', flush=True)
        survivors.append(name)
        continue
    open(p, 'w').write(t.replace(old, new, 1))
    ui_link(src)
    r = subprocess.run(['zig', 'build', '-Dgpu=false', '-p', f'{W}/out', '--cache-dir', f'{W}/zc', '--release=off'], cwd=src, capture_output=True, text=True)
    if r.returncode != 0:
        print(f'  ?    {name}: it does not build\n{r.stderr[-300:]}', flush=True)
        survivors.append(name)
        continue
    scen, _, only = scen.partition(':')
    r = subprocess.run([sys.executable, '-u', f'{HERE}/sculpt.py', f'{W}/out/bin/beemodel', '6', '1', *scen.split()], env=dict(os.environ, SCULPT_ONLY=only, BEERIG_TMP=os.environ.get('BEERIG_TMP', '/tmp')), capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln or 'Traceback' in ln]
    if fails or r.returncode != 0:
        print(f'  ok   {name}: {len(fails)} failed in {scen}: {fails[0].strip()[:90] if fails else r.stderr[-90:]}', flush=True)
    else:
        print(f'  LIVE {name}: nothing in {scen} failed', flush=True)
        survivors.append(name)
print('survivors', len(survivors), survivors)
shutil.rmtree(f'{W}/out', ignore_errors=True)
sys.exit(1 if survivors else 0)
