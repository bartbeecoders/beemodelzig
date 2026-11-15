#!/usr/bin/env python3
"""Each guard of tests/cad.py shown failing: the code it guards broken, one thing at
a time, in a copy of the sources; that part of the suite must then fail. A mutant
that survives is a test that passes on nothing. The copies build side by side;
the suite then runs on them one at a time (its windows are pinned to one CPU).

    python3 tests/cad_mutants.py WORKDIR [builds at a time=2] [name...]   (WORKDIR under /tmp: headless saves go nowhere else)
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
M = [  # name, file, old, new, the sections that must fail
    # --- expressions and parameters
    ('expr: no unit after a )', 'src/animexpr.zig', '        pos += 1;\n        return unit(v);', '        pos += 1;\n        return v;', 's_params'),
    ('params: a name of 24', 'src/cad.zig', 'if (!ok or k + 1 > 23) {', 'if (!ok or k + 1 > 24) {', 's_params'),
    ('params: a cycle is no error', 'src/cad.zig', '            if (xp.err == null) xp.err = e_cycle;\n            return null;', '            return 0;', 's_params'),
    ('params: a failed set stays', 'src/cad.zig', '            if (had) r.* = old else b.np -= 1;', '            _ = &had;\n            _ = &old;', 's_params'),
    ('params: quotes kept', 'src/cad.zig', '    if (cw_expr_n > 0 and cw_expr[0] == \'"\') {', '    if (false) {', 's_params'),
    ('units: inches are cm', 'src/cad.zig', 'pub const units_mm = [_]f64{ 1.0, 10.0, 1000.0, 25.4 };', 'pub const units_mm = [_]f64{ 1.0, 10.0, 1000.0, 10.0 };', 's_params'),
    ('file: no kernel switch', 'src/cad.zig', '    b.u32_(@intFromBool(kernel()));', '', 's_files'),
    ('file: any unit taken', 'src/cad.zig', '    if (u > 0) b.unit = u; // (a sane unit; NaN and negatives are not)', '    b.unit = u;', 's_files'),
    ('file: names not ended', 'src/cad.zig', '        b.params[k][23] = 0; // names and texts terminated', '', 's_files'),
    ('undo: the document not in the steps', 'src/scene.zig', '    @import("cad.zig").keep(&st.cad);\n', '', 's_undo'),
    ('undo: no step for a change', 'src/cad.zig', '    return sameBlock(cur, b);', '    _ = b;\n    return true;', 's_undo'),
    # --- measuring
    ('mass: the whole parallelogram', 'src/measure.zig', 'area = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) * 0.5 + area;', 'area = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) + area;', 's_measure'),
    ('mass: no density', 'src/measure.zig', '        if (ma.density > 0) dens = ma.density;', '        if (ma.density > 0) dens = 1;', 's_measure'),
    ('mass: kg from 100 g', 'src/measure.zig', '    const kg = p.mass >= 1000.0;', '    const kg = p.mass >= 100.0;', 's_measure'),
    ('tool: no snapping', 'src/measure.zig', '    var best: f32 = 196.0; // 14 px', '    var best: f32 = 0.0; // 14 px', 's_tool'),
    ('tool: the angle at the first point', 'src/measure.zig', 'val3(&w, vangle(vec(1, 0), vec(1, 2)) * 57.29577951308232);', 'val3(&w, vangle(vec(0, 1), vec(0, 2)) * 57.29577951308232);', 's_tool'),
    ('tool: Esc ignored', 'src/app.zig', '    if (@import("measure.zig").on and key == K.ESC) {', '    if (false) {', 's_tool'),
    # --- the print check
    ('walls: its own face hit', 'src/print.zig', '                if (g.me.tri_poly[t] == skip) continue;', '                _ = skip;', 's_print'),
    ('walls: the hair not added back', 'src/print.zig', '        if (t < BIG) t += EPS * g.diag; // (plus the hair it started inside)', '        if (t < BIG) t += 0 * g.diag;', 's_print'),
    ('overhangs: on the bed too', 'src/print.zig', 'if (p < fcls.len and fcls[p] & 2 != 0 and c[1] > bed) over += area;', 'if (p < fcls.len and fcls[p] & 2 != 0 and c[1] > bed - 1e9) over += area;', 's_print'),
    ('size: x y z', 'src/print.zig', '    for ([_]usize{ 0, 2, 1 }, 0..) |c, k| {', '    for ([_]usize{ 0, 1, 2 }, 0..) |c, k| {', 's_print'),
    ('walls: the minimum in metres', 'src/print.zig', '    const u: f32 = @floatCast(cad.unitMm());\n    return mm / u;', '    _ = cad;\n    return mm / 1000.0;', 's_print'),
    ('show: thin is under or at', 'src/print.zig', '                if (!(t >= minw)) selectFace(me, p);', '                if (!(t > minw * 1.5)) selectFace(me, p);', 's_panel'),
    ('panel: a move not noticed', 'src/print.zig', '        std.mem.eql(f32, &o.loc, &found.loc) and', '', 's_panel'),
    ('overlay: thin is yellow', 'src/analysis.zig', '            col = COL_THIN;\n', '            col = COL_THIN2;\n', 's_look'),
    ('overlay: the legend counts none', 'src/analysis.zig', '                if (!(t >= minw)) thin += 1;', '                if (!(t >= minw) and t > 1e30) thin += 1;', 's_look'),
    # --- the review's fixes (each one the current sources minus that fix)
    ('fields: the old parser', 'src/ui.zig', '    const x = @import("cad.zig").eval(text) orelse {', '    const x: f64 = @import("expr.zig").eval(text) orelse {', 's_fields'),
    ('fields: no has_letter', 'src/ui.zig', '    const d = if (deg and hasLetter(text)) x * (180.0 / std.math.pi) else x;', '    _ = deg;\n    const d = x;', 's_fields'),
    ('fields: the Rotation row plain', 'src/editors.zig', 'if ((if (ri == 1) &ui.numFieldDeg else &ui.numField)(fid, fr, &row.v[c], row.step, suf))', 'if ((&ui.numField)(fid, fr, &row.v[c], row.step, suf))', 's_fields'),
    ('fields: the world rotation plain', 'src/editors.zig', '"Rotation", .{ .step = 1, .lo = -360, .hi = 360, .dec = 1, .deg = true })', '"Rotation", .{ .step = 1, .lo = -360, .hi = 360, .dec = 1 })', 's_fields'),
    ('fields: a bad value not logged', 'src/ui.zig', '        @import("app.zig").log("not a value: {s}", .{text});\n', '', 's_fields'),
    ('print check: the console is quiet', 'src/print.zig', '    if (!ops.quiet) {', '    if (!ops.scripted) {', 's_review'),
    ('thin walls: the CAD document not in the view\'s key', 'src/viewport.zig', '    h.update(std.mem.asBytes(&@import("cad.zig").version));\n', '', 's_review'),
    ('New Sketch: a plain button', 'src/cadui.zig', '"New Sketch...", true); // (WGF_PRIMARY)', '"New Sketch...", false);', 's_review'),
    ('history: cad.sketch named Sketch', 'src/sketchui.zig', 'label("Script");', 'label("Sketch");', 's_review'),
    # --- 3MF
    ('zip: no CRC', 'src/fab.zig', '    return ~c;', '    return c;', 's_3mf'),
    ('3MF: Z down', 'src/fab.zig', '            try putFloat(&model, (0 - p[2]) * mm);', '            try putFloat(&model, p[2] * mm);', 's_3mf'),
    # --- shapes
    ('sdf: an unbounded shape meshed', 'src/sdf.zig', '        if (@abs(bb[c]) >= LIMIT or @abs(bb[c + 3]) >= LIMIT) {', '        if (false) {', 's_sdf'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)


def build(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copytree(f'{ROOT}/src', f'{d}/src')
    shutil.copy(f'{ROOT}/build.zig', d)
    # (build.zig.zon names Zui as ../BeeZigUi: a link to it next to the copies)
    shutil.copy(f'{ROOT}/build.zig.zon', d)
    zui = f'{W}/BeeZigUi'
    if not os.path.exists(zui):
        os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), zui)
    p = f'{d}/{fn}'
    t = open(p).read()
    if old not in t:
        return 'the code is not there'
    open(p, 'w').write(t.replace(old, new, 1))
    r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return 'it does not build: ' + r.stderr[-300:]
    return None


def run(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    e = dict(os.environ, CAD_ONLY=scen, BEECAD_TMP=os.environ.get('BEECAD_TMP', '/tmp'))
    r = subprocess.run([sys.executable, '-u', f'{HERE}/cad.py', f'{d}/out/bin/beemodel', '16', '4242'], env=e, capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if r.returncode != 0 and not fails:
        fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
    return ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:90]}' if fails else f'nothing in {scen} failed')


bad = []
# (a copy and its cache are some 300 MB: a few at a time, each gone once it ran)
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    futs = {}
    for k in range(min(JOBS, len(M))):
        futs[k] = ex.submit(build, k)
    for k in range(len(M)):
        why = futs.pop(k).result()
        name = M[k][0]
        if why:
            st, msg = '?', why
        else:
            st, msg = run(k)
        shutil.rmtree(f'{W}/m{k}', ignore_errors=True)
        if k + JOBS < len(M):
            futs[k + JOBS] = ex.submit(build, k + JOBS)
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
