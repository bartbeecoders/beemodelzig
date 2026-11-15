#!/usr/bin/env python3
"""Each guard of tests/library.py and tests/extlib.py shown failing: the code it
guards broken, one thing at a time, in a copy of the sources; that part of the
suite must then fail. A mutant that survives is a test that passes on nothing.
(Since BeeModel stopped being a port, the guards that only compared with the
original are gone, and so are their mutants: the asset id's hash, the
browser's pixels, the thumbnails' lens, Poly Haven's cut-out thumbnail, the
.complete marker's byte.)

    python3 tests/library_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

One debug build at a time by default (each about 300 MB; removed as it goes).
"""
import concurrent.futures, os, shutil, subprocess, sys

ROOT0 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def zig():
    """zig 0.17's own path: mise's when there is one (its shim on PATH finds
    no version outside mise.toml's folder, where the copies are), else PATH's."""
    try:
        r = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT0, capture_output=True, text=True)
        if r.returncode == 0 and os.path.isfile(r.stdout.strip()):
            return r.stdout.strip()
    except OSError:
        pass
    return shutil.which('zig') or 'zig'


ZIG = zig()  # (before temphome: a temp HOME hides mise's installs)
import temphome  # noqa: F401,E402 (a HOME of its own)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
L, X, U, E, A = 'src/library.zig', 'src/libui.zig', 'src/extlib.zig', 'library', 'src/asset.zig'
M = [  # name, file, old, new, suite, sections
    ('hash: the length not mixed in', L, '    h ^= d.len;\n', '', E, 's_save'),
    ('index line: no dash for no tags', L, 'w.writeAll(if (r.tags[0] == 0) "-" else r.tagsOf()) catch {};', 'w.writeAll(r.tagsOf()) catch {};', E, 's_save'),
    ('tags: a tag added twice', L, 'if (tagFind(&r.tags, word) != null) continue;', '', E, 's_save'),
    ('tags: removing leaves the comma', L, 'r.tags[if (p > 0) p - 1 else p] = 0;', 'r.tags[p] = 0;', E, 's_save'),
    ('objects: not relative to the first', L, 'for (0..3) |c| wp[c] -= anchor[c];', 'for (0..3) |c| wp[c] -= anchor[c] * 0;', E, 's_cross'),
    ('objects: base mesh, not evaluated', L, 'return @import("mods.zig").of(oi);', 'return scene.meshOfObj(oi);', E, 's_cross'),
    ('objects: no material name', L, '@memcpy(r[84..115], mn[0..31]);', '_ = mn;', E, 's_cross'),
    ('materials: image nodes kept', A, 'if (rd32(rec, at) == T_IMAGE) wr32(rec, at + 52, 0);', '_ = at;', E, 's_save'),
    ('trees: groups not renumbered', A, 'wr32(dst, at + nt.ND_P, @bitCast(@as(f32, @floatFromInt(p + 1))));', '_ = p;', E, 's_save'),
    ('pack: a blob written twice', L, 'if (x.hit != 0 and x.blob == r.blob) break true;', 'if (false and x.blob == r.blob) break true;', E, 's_save'),
    ('pack: no dependencies', L, 'if (tab[k].hit == 0) tab[k].hit = 2;', '_ = k;', E, 's_save'),
    ('place: not at the place', L, 'obj.loc = .{ f[0] + place_at[0], f[1] + place_at[1], f[2] + place_at[2] };', 'obj.loc = .{ f[0], f[1], f[2] };', E, 's_cross'),
    ('place: rig not bound', L, 'if (bound >= 0 and bound < placed) {', 'if (false) {', E, 's_cross'),
    ('place: materials not first', L, '        _ = load(k, false);\n', '', E, 's_cross'),
    ('import: a bad hash taken', L, 'if (h != std.mem.readInt(u64, c[0..8], .little)) continue;', '', E, 's_damaged'),
    ('index: a bad kind taken', L, 'if (kd == 0 or n >= MAX or byId(id) != null) return;', 'if (n >= MAX or byId(id) != null) return;', E, 's_damaged'),
    ('index: deps past 8 stored', L, 'if (nd < 8) {', 'if (nd < 9) {', E, 's_damaged'),
    ('beea: count not checked', A, 'if (cnt == 0 or cnt > MAXT or 16 + @as(usize, cnt) * TR_SZ > d.len)', 'if (cnt == 0 or cnt > MAXT)', E, 's_damaged'),
    ('undo: place not a step', X, '        ops.arg = id;\n        ops.run(i);', '        lib.runOp("lib.place", id);\n        _ = i;', E, 's_window'),
    ('browser: drop on the ground', X, 'scene.cursor = @import("viewport.zig").surfacePoint(ui.cv, &app.N(a).view, body_r, ui.mx, ui.my) orelse scene.cursor;', '_ = &scene.cursor;', E, 's_window'),
    ('online: .usda before .usd', U, 'if (tab[k].root[0] != 0) continue; // (.usd first: kept)', '', 'extlib', ''),
    ('online: everything fetched', U, 'if (len == 0 or !keep(p[0..len])) continue;', 'if (len == 0) continue;', 'extlib', ''),
    ('online: EXRs kept', U, 'if (std.mem.endsWith(u8, name, ".exr")) {', 'if (false) {', 'extlib', ''),
    ('online: no next page', U, 'if (nextLink(cstr(&s.hdr))) return;\n    state = 2;', 'state = 2;', 'extlib', ''),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon's path dependencies (../BeeZigUi) beside each copy
if os.path.isdir(os.path.join(ROOT, '..', 'BeeZigUi')) and not os.path.exists(os.path.join(W, 'BeeZigUi')):
    os.symlink(os.path.abspath(os.path.join(ROOT, '..', 'BeeZigUi')), os.path.join(W, 'BeeZigUi'))



def one(k):
    name, fn, old, new, suite, secs = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        for f in ('build.zig.zon',):
            if os.path.exists(f'{ROOT}/{f}'):
                shutil.copy(f'{ROOT}/{f}', d)
        if os.path.isdir(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        e = dict(os.environ, LB_ONLY=secs)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/{suite}.py', f'{d}/out/bin/beemodel'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed ({suite} {secs}): {fails[0].strip()[:90]}' if fails else f'nothing in {suite} {secs} failed')
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
