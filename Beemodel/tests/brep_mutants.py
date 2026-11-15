#!/usr/bin/env python3
"""Each guard of the B-rep kernel's suites shown failing: the code broken one
thing at a time in a copy of the sources; the named part of the suite must
then fail. A mutant that survives is a test that passes on nothing.

  unit:FILE   zig test src/FILE (the module's own tests, e.g. nurbscheck,
              the box built from STEP)
  s_*         that section of tests/step.py (STEP_QUICK: fewer fixtures)
  brep:s_*    those sections of tests/brep.py (BREP_ONLY), its driver built
              from the mutated copy

    python3 tests/brep_mutants.py WORKDIR [jobs=4] [name...]   (WORKDIR under /tmp)
"""
import concurrent.futures, os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
M = [  # name, file, old, new, what must fail
    # --- nurbs.zig: the basis, the evaluations, the constructions
    ('basis: saved from the wrong side', 'src/nurbs.zig', 'saved = ll * temp;', 'saved = rr * temp;', 'unit:nurbs.zig'),
    ('knot insertion: blend off', 'src/nurbs.zig', '            const beta = 1.0 - alpha;\n            for (0..4) |m| Rw[ui][m]', '            const beta = 1.0 - alpha * 1.0000001;\n            for (0..4) |m| Rw[ui][m]', 'unit:nurbs.zig'),
    ('revolved surfaces: Su turned', 'src/nurbs.zig', 'o[1] = lin3(null, &s.x, fneg(rho * su), &s.y, rho * cu, null, 0);', 'o[1] = lin3(null, &s.x, rho * su, &s.y, rho * cu, null, 0);', 's_import'),
    ('sine and cosine in SSE, not the x87', 'src/nurbs.zig', '    return sk.fsincos(a);', '    return .{ @sin(a), @cos(a) };', 's_import'),
    # --- brep.zig: inversion, pcurves, integration, counts
    ('poles: never found', 'src/brep.zig', 't *= br_pole;', 't *= 0;', 's_import'),
    ('pcurves: straight more often', 'src/brep.zig', 'const tol = d * br_lin + br_nwt;', 'const tol = d * 1.0e-3 + br_nwt;', 's_import'),
    ('pcurves: refined to a looser tolerance', 'src/brep.zig', 'tol = tol * br_pctol + br_nwt;', 'tol = tol * 1.0e-6 + br_nwt;', 's_import'),
    ('integration: no weights across u', 'src/brep.zig', 'v = v * gl_w[n];', 'v = v * 0.25;', 's_import'),
    ('edges counted per use', 'src/brep.zig', 'if (e.mark == 0) bs_e += 1;', 'bs_e += 1;', 's_import'),
    # --- btess.zig, proftri.zig: the tessellation
    ('edges: a coarser chord', 'src/btess.zig', 'if (jbe(d, bt_tol)) {', 'if (jbe(d, bt_tol * 1.5)) {', 's_import'),
    ('the size tolerance', 'src/btess.zig', 'const bt_rel: f64 = 2.0e-4;', 'const bt_rel: f64 = 2.5e-4;', 's_import'),
    ('inner points nearer the boundary', 'src/btess.zig', 'keep = keep * bt_keep;', 'keep = keep * 0.3;', 's_import'),
    ('incircle: one term lost', 'src/btess.zig', '    r = r + s;\n', '    r = r + s * 0.5;\n', 's_import'),
    ('no Delaunay flips', 'src/btess.zig', '    ctDelaunay();\n    if (ft_curved)', '    if (ft_curved)', 's_import'),
    ('ear clipping gives up sooner', 'src/proftri.zig', 'if (fails > n) {', 'if (fails > 1) {', 's_import'),
    # --- stepread.zig
    ('reals: no x87', 'src/stepread.zig', 'var bits: u64 = @bitCast(x87Real(@bitCast(m), e));', 'var bits: u64 = @bitCast(@as(f64, @floatFromInt(m)) * std.math.pow(f64, 10, @floatFromInt(e)));', 's_import'),
    ('faces round a seam not fixed', 'src/stepread.zig', '    fixWrap(fi);\n', '', 's_import'),
    ('no degenerate edges at poles', 'src/stepread.zig', '            } else poleEdge(v, surf);', '            } else {}', 's_import'),
    ('units: a millimetre a little long', 'src/stepread.zig', 'if (nIs(pre, "MILLI")) return 1.0;', 'if (nIs(pre, "MILLI")) return 1.0000001;', 's_import'),
    ('turns: X angle from the wrong axes', 'src/stepread.zig', 'const a = nb.datan2(f[2][2], f[3][2]);', 'const a = nb.datan2(f[3][2], f[2][2]);', 's_import'),
    ('colours: truncated', 'src/stepread.zig', 'nb.cvtr(nReal(eArg(rgb, i)) * 255.0)', 'nb.cvtt(nReal(eArg(rgb, i)) * 255.0)', 's_import'),
    ('names keep quotes', 'src/stepread.zig', "if (c < ' ' or c == 0x27) continue;", "if (c < ' ') continue;", 's_import'),
    ('no nesting limit', 'src/stepread.zig', 'if (sp_depth > MAXDEPTH) {', 'if (false) {', 's_damaged'),
    ('reference cycles followed for ever', 'src/stepread.zig', 'if (depth > MAXCHAIN) return nb.v3scale(sr_z, 1.0);', '', 's_damaged'),
    ('more than 16 files kept', 'src/stepread.zig', 'pub const MAXIMP = 16;', 'pub const MAXIMP = 32;', 's_undo'),
    # --- step.zig
    ('reals: 16 digits', 'src/step.zig', 'r = scaled(a, 16 -% e);', 'r = scaled(a, 15 -% e);', 's_import'),
    ('surface knots not interleaved', 'src/step.zig', 'wbStr(all[0 .. us - ub0]); // um', 'wbStr(all[0 .. us - ub0]);\n    wbChar(\',\');', 's_import'),
    ('edges: sense always true', 'src/step.zig', 'wBool(e.t1 > e.t0);', 'wBool(true);', 's_import'),
    ('one solid not placed', 'src/step.zig', '        if (n == 1) {\n            objFrame', '        if (n == 0) {\n            objFrame', 's_import'),
    # --- the commands, the window
    ('import: the wrong message', 'src/stepops.zig', 'app.log("  no solids in {s}", .{p});', 'app.log("  imported {s}", .{p});', 's_damaged'),
    ('the browser takes every file', 'src/stepops.zig', '"Import STEP", ".step .stp", "", importLater', '"Import STEP", ".step .stp .txt", "", importLater', 's_window'),
    ('objects not undone with the import', 'src/stepops.zig', '    scene.stamp(scene.count);\n    scene.count += 1;\n    return', '    scene.stamp(scene.count);\n    scene.count += 1;\n    @import("undo.zig").restart();\n    return', 's_undo'),
    # --- the boolean side (tests/brep.py on its own; brep:SECTIONS, BREP_ONLY)
    # (gone with the comparison to the original, whose guard was a value or a
    # triangle count only: pcurves refined to a coarse tolerance, arcs over half
    # a turn kept whole, a part turn in one patch, edges every 16 degrees, looser
    # or coarser or undensified sections)
    # (equivalent on every input the suite makes, so not listed: tilted planes paired when
    # parallel, saddle cells paired the other way, a vertex crossed twice within one
    # section segment, a hole between two nested outer cycles of one face; edge_root's
    # Illinois halving or a looser stop: the suite's crossings converge in one step)
    ('nurbs: elevation with the wrong alpha', 'src/nurbs.zig', 'const alpha = fl(k) / pp1;', 'const alpha = fl(k) / (pp1 + 1.0);', 'brep:s_nurbs'),
    ('nurbs: derivatives not scaled', 'src/nurbs.zig', 'while (j <= p) : (j += 1) out[k][j] *= m;', 'while (j <= p) : (j += 1) out[k][j] *= 1.0;', 'brep:s_nurbs'),
    ('nurbs: torus Sv sign', 'src/nurbs.zig', 'o[2] = lin3(null, &s.x, fneg(sv * r * cu), &s.y, fneg(sv * r * su), &s.z, cvv * r);', 'o[2] = lin3(null, &s.x, sv * r * cu, &s.y, fneg(sv * r * su), &s.z, cvv * r);', 'brep:s_solids'),
    ('brep: a turned face counts the same in areas', 'src/brep.zig', 'const m: f64 = if (kind != 0 and f.sense != 0) -1.0 else 1.0;', 'const m: f64 = 1.0;', 'brep:s_solids'),
    ('brep: angles not wrapped to the hint', 'src/brep.zig', 'const u = wrap(nb.datan2(y, x), uh);', 'const u = nb.datan2(y, x);', 'brep:s_solids,s_bool'),
    ('brep: edges used once are valid', 'src/brep.zig', 'if (e.mark == 0x10001) continue;\n                    bs_bad += 1;', 'if (e.mark != 0xdead) continue;\n                    bs_bad += 1;', 'brep:s_bool,s_fuzz'),
    ('bbuild: the cone half angle signed', 'src/bbuild.zig', 'const ang = nb.datan2(dr, fabs(dz));', 'const ang = nb.datan2(dr, dz);', 'brep:s_solids'),
    ('bbuild: shell walls offset the wrong way', 'src/bbuild.zig', 'e.a[1] = e.a[1] + dx;\n        e.b[1] = e.b[1] + dx;', 'e.a[1] = e.a[1] - dx;\n        e.b[1] = e.b[1] - dx;', 'brep:s_bool'),
    ('bbuild: loose points welded far', 'src/bbuild.zig', 'const bb_weld: f64 = 1.0e-7;', 'const bb_weld: f64 = 0.2;', 'brep:s_fuzz'),
    ('btess: an edge inner point off by one', 'src/btess.zig', 'return e.aux +% np -% 1;', 'return e.aux +% np;', 'brep:s_solids'),
    ('proftri: ears emitted turned', 'src/proftri.zig', 'pf_tri[pf_ntri] = .{ tr_v[prev], tr_v[cur.*], tr_v[next] };', 'pf_tri[pf_ntri] = .{ tr_v[cur.*], tr_v[next], tr_v[prev] };', 'brep:s_solids'),
    ('bbool: union keeps coplanar faces facing apart', 'src/bbool.zig', 'const want = if (bo_op == OP_UNION) C_SAME else C_OPP;', 'const want = if (bo_op == OP_UNION) C_OPP else C_SAME;', 'brep:s_bool'),
    ('bbool: vertices welded far', 'src/bbool.zig', 'const bo_rweld: f64 = 1.0e-8;', 'const bo_rweld: f64 = 1.0e-3;', 'brep:s_bool,s_fuzz'),
    ('bbool: cycles turn the widest way', 'src/bbool.zig', 'if (jae(a, best)) continue;\n                best = a;\n                best_i = c;', 'if (jbe(a, best) and best != bo_big) continue;\n                best = a;\n                best_i = c;', 'brep:s_bool'),
    ('bbool: circle edges from the wrong angle', 'src/bbool.zig', 'return nb.datan2(nb.v3dot(d, c.y), x);', 'return nb.datan2(x, nb.v3dot(d, c.y));', 'brep:s_bool'),
    ('breptest: pockets without the overshoot', 'src/breptest.zig', 'const ov = x * 0.02;', 'const ov = x * 0.0;', 'brep:s_bool'),
    ('bbuild: loops flipped with an unsigned bound (the original\'s crash)', 'src/bbuild.zig', 'while (@as(i64, a) <= b) {', 'while (@as(u32, @truncate(@as(u64, @bitCast(b)))) >= a) {', 'brep:s_damaged'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, what = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        for x in ('build.zig.zon', 'mise.toml'):  # (mise.toml: the zig version mise's shim runs)
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        if what.startswith('brep:'):
            r = subprocess.run(['zig', 'build-exe', f'{d}/src/breptest.zig', '-OReleaseSafe', '--cache-dir', f'{d}/zc',
                                f'-femit-bin={d}/breptest'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
            if r.returncode != 0:
                return name, '?', 'it does not build: ' + r.stderr[-300:]
            e = dict(os.environ, BREP_ONLY=what[5:], BREP_DRIVER=f'{d}/breptest', BEE_CPU='none')
            if 's_damaged' in what:   # (the debug driver, from the mutated sources)
                e['BREP_DEBUG_SRC'] = f'{d}/src/breptest.zig'
            r = subprocess.run([sys.executable, '-u', f'{HERE}/brep.py', 'x', '30', '4242'],
                               env=e, capture_output=True, text=True, timeout=3600)
            fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
            if r.returncode != 0 and not fails:
                fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
            return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {what}: {fails[0].strip()[:90]}' if fails else f'nothing in {what} failed')
        if what.startswith('unit:'):
            r = subprocess.run(['zig', 'test', f'src/{what[5:]}', '--cache-dir', f'{d}/zc'], cwd=d, capture_output=True, text=True, timeout=1800, env=BUILD_ENV)
            ok = r.returncode != 0
            return name, ('ok' if ok else 'LIVE'), (f'{what} failed: ' + (r.stderr.strip().splitlines() or ['?'])[-1][:90] if ok else f'{what} passed')
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, STEP_ONLY=what, STEP_QUICK='1')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/step.py', f'{d}/out/bin/beemodel', '12', '4242'],
                           env=e, capture_output=True, text=True, timeout=7200)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {what}: {fails[0].strip()[:90]}' if fails else f'nothing in {what} failed')
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
