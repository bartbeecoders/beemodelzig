#!/usr/bin/env python3
"""Each guard of tests/paint.py shown failing: the code it guards broken, one thing at a
time, in a copy of the sources; that part of the suite must then fail. A mutant that
survives is a test that passes on nothing.

    python3 tests/paint_mutants.py WORKDIR [name...]   (each builds: minutes)

(Gone since BeeModel stopped being a port: the mutants of the dab's falloff, spacing,
bleed and depth slack, the blend's rounding, the composite's modes, the weights' slots,
the heat's colours and the UV Editor's rows - only the original's texels, colours and
weights caught them; a script and the console share that code.)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, scenarios that must fail ("scen:only")
    ('depth ignored', 'src/paint.zig', 'if (!inFront(s[0], s[1], s[2])) continue;\n            blendTexel(d.e, b, x, y, amount);', 'blendTexel(d.e, b, x, y, amount);', 's_depth'),
    ('blend: alpha stays', 'src/paint.zig', 'o[3] = 255; // (no layers: opaque)', 'o[3] = c[3];', 's_files'),
    ('layer: no composite', 'src/paint.zig', '        layers.texel(e, st_layers.?, i);\n', '', 's_layers'),
    ('layers: 17', 'src/layers.zig', 'if (b.count >= MAX) return -1;', 'if (b.count > MAX) return -1;', 's_layers'),
    ('layers: not saved', 'src/bee.zig', '@import("layers.zig").writeChunk(&b);', '', 's_files'),
    ('layers: not read', 'src/bee.zig', 'if (ilay) |c| @import("layers.zig").readChunk(c);', 'if (ilay != null and images.count > 9999) @import("layers.zig").readChunk(ilay.?);', 's_files'),
    ('layers: active lost', 'src/layers.zig', 'b.active = if (active < b.count) active else 0;', 'b.active = if (active > 1 << 30) active else 0;', 's_files'),
    ('colours: not saved', 'src/bee.zig', '@import("vcol.zig").writeChunk(&b, &mesh_ix);', '', 's_files'),
    ('colours: not read', 'src/bee.zig', 'if (mvcl) |c| @import("vcol.zig").readChunk(c, mesh_map);', 'if (mvcl != null and scene.count > 9999) @import("vcol.zig").readChunk(mvcl.?, mesh_map);', 's_files'),
    ('colours: lost when the skin is applied', 'src/mods.zig', 'if (copies) @import("vcol.zig").keep(', 'if (copies and false) @import("vcol.zig").keep(', 's_weights'),
    ('colours: not copied', 'src/scene.zig', 'me.vcol = if (s.vcol.len > 0) (alloc_.dupe(u32, s.vcol) catch &.{}) else &.{};', 'me.vcol = &.{};', 's_vcol'),
    ('vertex: alpha zero', 'src/paint.zig', 'var o: u32 = 0xff000000;', 'var o: u32 = 0;', 's_vcol'),
    ('solid: no tint', 'src/viewport.zig', 'if (fsel) base = FACE_SEL else if (tint) base = paintTint(oi, mesh, ti, base);', 'if (fsel) base = FACE_SEL else if (tint and oi > 99999) base = paintTint(oi, mesh, ti, base);', 's_look'),
    ('preview: no tint', 'src/preview.zig', '                    s.tint(c);\n', '                    if (c[0] > 99) s.tint(c);\n', 's_look'),
    ('render: no tint', 'src/surface.zig', '    if (!hasVcol(h.tri)) return ma;\n', '    if (h.t > -1) return ma;\n', 's_look'),
    ('stale: viewport', 'src/paint.zig', '    version +%= 1;\n    material.version +%= 1;\n    app.dirty = true;\n}\n\nfn oneDab', '    app.dirty = true;\n}\n\nfn oneDab', 's_look'),
    ('stale: undo', 'src/pthist.zig', '    @import("material.zig").version +%= 1;\n', '', 's_look'),
    ('undo: no box, nothing back', 'src/pthist.zig', 'for (buf[o..][0..s.w], s.px[r * s.w..][0..s.w]) |*a, *b| std.mem.swap([4]u8, a, b);', 'if (o > 1 << 40) for (buf[o..][0..s.w], s.px[r * s.w..][0..s.w]) |*a, *b| std.mem.swap([4]u8, a, b);', 's_undo'),
    ('undo: whole image a step', 'src/paint.zig', 'pthist.commitBox(st_im, st_layer, before, @intCast(st_x0), @intCast(st_y0), @intCast(st_x1), @intCast(st_y1));', 'pthist.commitBox(st_im, st_layer, before, 0, 0, images.list[st_im].img.w - 1, images.list[st_im].img.h - 1);', 's_undo'),
    ('undo: 33 steps', 'src/pthist.zig', 'const HIST_N = 32;', 'const HIST_N = 33;', 's_undo'),
    ('undo: stroke in the way', 'src/pthist.zig', 'pub fn opUndo() void {\n    @import("paint.zig").finishStroke(); // (a stroke under way is a step first)\n', 'pub fn opUndo() void {\n', 's_undo'),
    ('undo: delta not put back', 'src/paint.zig', '        applyRecs(u32, me.vcol, h, back);\n', '', 's_undo'),
    ('undo: colours stay when made', 'src/paint.zig', '        if (h.made and back) {\n            @import("alloc.zig").A.free(me.vcol);', '        if (h.made and back and h.n > 1 << 40) {\n            @import("alloc.zig").A.free(me.vcol);', 's_undo'),
    ('undo: weights skin stale', 'src/paint.zig', 'scene.bumpShape(h.mi); // (the skin follows)', '', 's_undo'),
    ('shared: a primitive painted', 'src/paint.zig', '    if (sharedMesh(oi, mi0)) {', '    if (false) {', 's_undo'),
    ('leaving: the stroke lost', 'src/paint.zig', 'fn leave() void {\n    finishStroke();\n', 'fn leave() void {\n    stroking = false;\n', 's_undo'),
    ('restart: steps kept', 'src/images.zig', '    @import("pthist.zig").clear();\n', '', 's_undo'),
    ('layer change: steps kept', 'src/layers.zig', '            pthist.clear(); // (strokes point at layers)\n', '', 's_undo'),
    ('file: painted is no change', 'src/pthist.zig', '    @import("files.zig").noteChange();\n    @import("autosave.zig").note();\n', '', 's_undo'),
    ('bake: into the image', 'src/bake.zig', 'const buf = layers.target(e); // (where: the image, its active layer)', 'const buf = e.b8;', 's_bake'),
    ('bake: no composite', 'src/bake.zig', 'if (e.layers != null) layers.rect(e, 0, 0, e.img.w - 1, e.img.h - 1); // (done: composite)', '', 's_bake'),
    ('keys: everywhere', 'src/ops.zig', 'if (im.ctx == .paint) return i;', 'if (im.ctx == .paint and false) return i;', 's_ui'),
    ('radius unbounded', 'src/paintui.zig', 'pt.radius = stroke.minss(stroke.maxss(pt.radius * k, pt.rmin), pt.rmax);', 'pt.radius = pt.radius * k;', 's_ui'),
    ('layers not greyed', 'src/paintui.zig', 'return if (pt.kind == .texture) null else "Only texture paint has layers";', 'return null;', 's_ui'),
    ('one mode at a time', 'src/ops.zig', '    sculpt.exit(); // (one mode at a time)\n    paint.exit();\n', '    sculpt.exit(); // (one mode at a time)\n', 's_ui'),
    ('idle: a frame for ever', 'src/main.zig', 'app.frameDrawn();\n                app.dirty = false;', 'app.frameDrawn();\n                app.dirty = @import("paint.zig").on;', 's_idle'),
    ('damaged: a colour array too long', 'src/vcol.zig', 'if (n != me.verts.len or n == 0) continue;', 'if (n == 0) continue;', 's_robust'),
    ('damaged: no end check', 'src/layers.zig', 'if (n > d.len - o - 16) return done(e, active);', '', 's_robust'),
    ('damaged: a layer of another size', 'src/layers.zig', 'if (img.w != e.img.w or img.h != e.img.h or img.hdr or img.px.len != l.px.len) return;', 'if (img.hdr or e.img.w == 0) return;', 's_robust'),
    ('float image painted', 'src/paint.zig', 'return if (images.list[i].b8.len > 0) i else null;\n    }\n    return null;\n}\n\n/// The image painted', 'return i;\n    }\n    return null;\n}\n\n/// The image painted', 's_robust'),
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
        if os.path.exists(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{src}/zig-pkg')
    # (build.zig.zon takes the UI library from ../BeeZigUi: beside the copy too)
    if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
        os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
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
    for _ in range(3):  # (another's edit may be half done)
        r = subprocess.run(['zig', 'build', '-Dgpu=false', '-p', f'{W}/out', '--cache-dir', f'{W}/zc', '--release=off'], cwd=src, capture_output=True, text=True)
        if r.returncode == 0:
            break
    if r.returncode != 0:
        print(f'  ?    {name}: it does not build\n' + '\n'.join(ln for ln in r.stderr.splitlines() if 'error:' in ln)[:400], flush=True)
        survivors.append(name)
        continue
    shutil.rmtree(f'{W}/zc', ignore_errors=True)  # (a build's cache is a gigabyte)
    scen, _, only = scen.partition(':')
    r = subprocess.run([sys.executable, '-u', f'{HERE}/paint.py', f'{W}/out/bin/beemodel', '6', '1', *scen.split()], env=dict(os.environ, PAINT_ONLY=only, BEERIG_TMP=os.environ.get('BEERIG_TMP', '/tmp')), capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln or 'Traceback' in ln]
    if fails or r.returncode != 0:
        print(f'  ok   {name}: {len(fails)} failed in {scen}: {fails[0].strip()[:90] if fails else r.stderr[-90:]}', flush=True)
    else:
        print(f'  LIVE {name}: nothing in {scen} failed', flush=True)
        survivors.append(name)
print('survivors', len(survivors), survivors)
shutil.rmtree(f'{W}/out', ignore_errors=True)
sys.exit(1 if survivors else 0)
