#!/usr/bin/env python3
"""Each guard of tests/rig.py shown failing: the code it guards broken, one thing at
a time, in a copy of the sources; that part of the suite must then fail. A mutant
that survives is a test that passes on nothing.

    python3 tests/rig_mutants.py WORKDIR [name...]   (each builds: minutes)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the scenarios that must fail
    ('roll ignored', 'src/arm.zig', 'o[c * 4] = x[c] * sc[1] + z[c] * sc[0];', 'o[c * 4] = x[c] * sc[1] - z[c] * sc[0];', 's_roll'),
    ('parent matrix skipped', 'src/arm.zig', 'am_m[i] = mMul(&t2, &rp);', 'am_m[i] = rp;\n            _ = t2;', 's_pose'),
    ('skin ignores the mesh object', 'src/arm.zig', 'const n = mInv(&t2);', 'const n = t2;', 's_pose'),
    ('dual quaternions: no hemisphere', 'src/arm.zig', 'if (!(dot4(&q0, qr) >= 0)) w = -w;', 'if (dot4(&q0, qr) > 1e30) w = -w;', 's_dual'),
    ('linear: weights not normalised', 'src/arm.zig', 's.out[v][k] = sum[k] / sw;', 's.out[v][k] = sum[k];', 's_weights'),
    ('heat: fewer iterations', 'src/arm.zig', 'const HW_ITERS = 400;', 'const HW_ITERS = 399;', 's_heat'),
    ('heat: neighbours summed the other way', 'src/arm.zig', 'for (j.nb[a..e]) |n| s = s + w[n];', 'var q2 = e;\n                while (q2 > a) {\n                    q2 -= 1;\n                    s = s + w[j.nb[q2]];\n                }', 's_heat'),
    ('weights kept on a new topology', 'src/arm.zig', 'if (me.wgt.len > 0 or from.wgt.len != me.verts.len or from.wgt.len == 0) return;', 'if (me.wgt.len > 0 or from.wgt.len == 0) return;', 's_weights'),
    ('ARMT: pose dropped on read', 'src/arm.zig', 'saneF(&x.loc, 0);', 'x.loc = .{ 0, 0, 0 };', 's_files'),
    ('MWGT not written', 'src/bee.zig', '@import("arm.zig").writeMwgt(&b, &mesh_ix);', '', 's_files'),
    ('modifier handle: index + 1', 'src/mods.zig', 'return 1 << 24 | @as(u32, @intCast(i));', 'return @intCast(i + 1);', 's_heat'),
    ('fabrik: no pole', 'src/rig.zig', '        poleTurn();\n', '', 's_ik'),
    ('ccd is fabrik', 'src/rig.zig', 'if (c.track == 1) ccd(iters) else fabrik(iters);', 'fabrik(iters);', 's_ik'),
    ('ik influence ignored', 'src/rig.zig', 'for (0..ik_n + 1) |j| {\n        for (0..3) |k| ik_p[j][k] = (ik_p[j][k] - ik_o[j][k]) * inf + ik_o[j][k];\n    }', '', 's_ik'),
    ('constraint influence ignored', 'src/rig.zig', 'for (t, prev) |*x, q| x.* = (x.* - q) * inf + q;', '_ = prev;', 's_constraints'),
    ('track: up ignored', 'src/rig.zig', 'var up: u32 = if (c.up < 3) c.up else 0;', 'var up: u32 = 1;', 's_constraints'),
    ('child of: no inverse', 'src/rig.zig', 'const a2 = arm.mMul(&a, c.inv[0..12]);', 'const a2 = a;', 's_constraints'),
    ('limit: min ignored', 'src/rig.zig', 't[o + k] = maxss(minss(t[o + k], c.max[k]), c.min[k]);', 't[o + k] = minss(t[o + k], c.max[k]);', 's_constraints'),
    ('offset ignored', 'src/rig.zig', 'if (c.flags & F_OFFSET != 0) {', 'if (false) {', 's_constraints'),
    ('edit moves pose not joints', 'src/armedit.zig', 'if (e.part == 0) x.head = l else x.tail = l;', 'if (e.part == 0) x.tail = l else x.head = l;', 's_modes'),
    ('pose rotate: no frame', 'src/armedit.zig', 'const pn = arm.mMul(&fi, &nw);', 'const pn = nw;\n        _ = fi;', 's_modes'),
    ('delete: weights not renumbered', 'src/armedit.zig', 'g.bone[c] = nb;\n', '', 's_delete'),
    ('cancel leaves a step', 'src/armedit.zig', 'scene.objects[i].mesh = mi;\n            return;', 'return;', 's_undo'),
    ('undo: an edit in place', 'src/arm.zig', 'const c = ownMesh(i, undo.holdsMesh(o.mesh.?)) orelse return null;', 'const c = ownMesh(i, o.mesh.? == 0xffff) orelse return null;', 's_undo'),
    ('damaged: no sanity', 'src/arm.zig', 'if (n > MAXB) {', 'if (false) {', 's_damage'),
    ('damaged: parents ahead', 'src/arm.zig', 'if (x.parent >= @as(i32, @intCast(k))) x.parent = -1;', '_ = k;', 's_damage'),
    ('damaged: NaN kept', 'src/arm.zig', 'if (!std.math.isFinite(x.*) or @abs(x.*) > 1e7) x.* = bad;', 'x.* = x.* + 0 * bad;', 's_damage'),
    ('idle: a rig keeps drawing', 'src/main.zig', 'app.frameDrawn();\n                app.dirty = false;', 'app.frameDrawn();\n                app.dirty = if (@import("anim.zig").cur) |ab| ab.h.ncon != 0 else false;', 's_window'),
    ('bone path: the object', 'src/armedit.zig', 'who[n] = .{ scene.objects[i].oid, @intCast(k) };', 'who[n] = .{ scene.objects[i].oid, @as(i64, @intCast(k)) * 0 };', 's_paths'),
    ('armature exported', 'src/scene.zig', '.light, .camera, .armature => false,', '.light, .camera => false,', 's_paths'),
    ('undo: a pass folds whatever is there', 'src/undo.zig', 'if (eval_state != .clean) return;\n    const st = &states[slot(cur)];\n    if (i >= st.count', 'const st = &states[slot(cur)];\n    if (i >= st.count', 's_eval_undo'),
    ('undo: every pass thinks it clean', 'src/undo.zig', 'if (eval_state == .unknown) eval_state = if (scene.differs(&states[slot(cur)])) .under_edit else .clean;', 'if (eval_state == .unknown) eval_state = .clean;', 's_eval_undo'),
    ('undo: no pass folds', 'src/undo.zig', 'if (eval_state == .unknown) eval_state = if (scene.differs(&states[slot(cur)])) .under_edit else .clean;', 'if (eval_state == .unknown) eval_state = .under_edit;', 's_eval_undo'),
    ('undo: a material folds under an edit', 'src/undo.zig', 'pub fn absorbMat(k: usize) void {\n    if (eval_state != .clean) return;', 'pub fn absorbMat(k: usize) void {', 'a:s_mat_undo'),
    ('frame: bones in place', 'src/arm.zig', 'if (undo.evalHolds(mi) or sharedLive(i, mi)) {', 'if (sharedLive(i, mi)) {', 's_undo_keys'),
    ('frame: bones copied each write', 'src/arm.zig', 'if (undo.evalHolds(mi) or sharedLive(i, mi)) {', 'if (true or undo.evalHolds(mi) or sharedLive(i, mi)) {', 's_undo_keys'),
    ('frame: only others count, under an edit too', 'src/undo.zig', 'return eval_state != .clean and holdsMesh(mi);', 'return false and holdsMesh(mi);', 's_undo_keys'),
    ('frame: shape values in place', 'src/shape.zig', 'if (mi == m0 and undo.evalHolds(m0)) {', 'if (false) {', 'a:s_undo_shapes'),
    ('a key file: any frame', 'src/anim.zig', 'if (!std.math.isFinite(k.f)) return false;', '_ = k;', 'a:s_bad_frames'),
    ('keys: scaled to nowhere', 'src/animops.zig', 'if (!std.math.isFinite(f)) f = k.f;', '_ = &f;', 'a:s_bad_frames'),
    ('keys: moved past a float', 'src/animops.zig', 'if (!std.math.isFinite(v)) v = k.v;', '_ = &v;', 'a:s_bad_frames'),
    ('unkey: copies for nothing', 'src/anim.zig', 'const ci = find(ch, act) orelse return false;\n    const b0 = cur.?;', 'const ci = find(ch, act) orelse return false;\n    _ = own(0);\n    const b0 = cur.?;', 'a:s_no_step'),
    ('constraint.remove: copies for nothing', 'src/rig.zig', 'const b0 = anim.cur orelse return app.log("  no such constraint: {s}", .{w});', 'const b0 = anim.own(0) orelse return app.log("  no such constraint: {s}", .{w});', 'a:s_no_step'),
    ('delete_key: no step', 'src/animops.zig', 'if (anim.cur != null) _ = anim.own(0);', '', 'a:s_no_step'),
    ('range: a huge speed', 'src/animops.zig', 'if (fps < 1e9) {', 'if (true) {', 'a:s_no_step'),
    ('form: Target Cube', 'src/forms.zig', '.{ .label = "Target", .kind = .text },', '.{ .label = "Target", .kind = .text, .words = &.{"Cube"} },', 's_forms'),
    ('form: Object fixed', 'src/forms.zig', 'if (fd.kind == .active) {\n                keepText(q, activeName());', 'if (fd.kind == .active) {\n                keepText(q, "Cube");', 's_forms'),
    ('form: an emptied Object loses its place', 'src/forms.zig', '.{ .label = "Object", .kind = .active, .empty = "-" },', '.{ .label = "Object", .kind = .active },', 's_forms'),
    ('form: a click away drops the text', 'src/forms.zig', 'if (ui.hit and ui.pressed != 0 and ui.edit_id == tid and !ui.inside(tr)) keepEdit();', '', 's_forms'),
]
want = sys.argv[2:]
src = f'{W}/src'
# Zig 0.17 from mise when the copy has no mise.toml of its own
ZIG_ENV = dict(os.environ, PATH=os.path.expanduser('~/.local/share/mise/installs/zig/0.17.1/bin') + os.pathsep + os.environ.get('PATH', ''))
survivors = []
for name, fn, old, new, scen in M:
    if want and name not in want:
        continue
    if not os.path.exists(f'{src}/build.zig'):
        os.makedirs(src, exist_ok=True)
        shutil.copytree(f'{ROOT}/src', f'{src}/src')
        shutil.copy(f'{ROOT}/build.zig', src)
        # (build.zig.zon names BeeZigUi as ../BeeZigUi: a link to it next to the copy)
        shutil.copy(f'{ROOT}/build.zig.zon', src)
        if not os.path.lexists(f'{W}/BeeZigUi'):
            os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
    for x in os.listdir(f'{ROOT}/src'):
        if x.endswith('.zig'):
            q = f'{src}/src/{x}'
            t = open(f'{ROOT}/src/{x}').read()
            if open(q).read() != t:
                open(q, 'w').write(t)
    p = f'{src}/{fn}'
    t = open(p).read()
    if old not in t:
        print(f'  ?    {name}: the code is not there', flush=True)
        survivors.append(name)
        continue
    open(p, 'w').write(t.replace(old, new, 1))
    r = subprocess.run(['zig', 'build', '-p', f'{W}/out'], cwd=src, capture_output=True, text=True, env=ZIG_ENV)
    if r.returncode != 0:
        print(f'  ?    {name}: it does not build\n{r.stderr[-300:]}', flush=True)
        survivors.append(name)
        continue
    # (a: a scenario of tests/anim.py)
    script, only = ('anim.py', scen[2:]) if scen.startswith('a:') else ('rig.py', scen)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/{script}', f'{W}/out/bin/beemodel'], env=dict(os.environ, RIG_ONLY=only, ANIM_ONLY=only, BEERIG_TMP=os.environ.get('BEERIG_TMP', W)), capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if fails:
        print(f'  ok   {name}: {len(fails)} failed in {scen}: {fails[0].strip()[:90]}', flush=True)
    else:
        print(f'  LIVE {name}: nothing in {scen} failed', flush=True)
        survivors.append(name)
print('survivors', len(survivors), survivors)
sys.exit(1 if survivors else 0)
