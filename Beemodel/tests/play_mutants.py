#!/usr/bin/env python3
"""Each guard of tests/play.py and tests/logic.py shown failing: the code it
guards broken, one thing at a time, in a copy of the sources; that part of the
suites must then fail. A mutant that survives is a test that passes on nothing.
(The guards that were the original's numbers bit for bit went with it, and
their mutants too: what is left fails on what play and the graphs do.)

    python3 tests/play_mutants.py WORKDIR [runs=2] [name...]

One at a time (every run is pinned to BEE_CPU, default 12); each build (release:
small) has a cache of its own in WORKDIR, removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '2'
M = [  # name, file, old, new, suite, the sections that must fail
    # --- the player
    ('ground up to 60 degrees', 'src/play.zig', 'const ground_cos: f32 = 0.64; // 50 degrees', 'const ground_cos: f32 = 0.5;', 'play', 's_walk,s_edges'),
    ('no step up', 'src/play.zig', '    if (was_ground and wall) tryStep(); // blocked on the ground: a step?', '', 'play', 's_walk'),
    ('the frame does not turn with the pull', 'src/play.zig', '    turn(neg3(unit(a)));', '    _ = unit(a);', 'play', 's_planet'),
    ('no riding', 'src/play.zig', '    pos = andXyz(V{ l[0], l[1], l[2], 0 } - V{ gloc[0], gloc[1], gloc[2], 0 }) + pos;', '    _ = l;', 'play', 's_ride'),
    ('F does not switch', 'src/play.zig', '        mode ^= 3;', '', 'play', 's_keys'),
    ('Esc asks nothing', 'src/play.zig', '        on = 2; // stopped: the question', '        on = 1;', 'play', 's_keys,s_window'),
    ('a discard keeps the scene', 'src/play.zig', '        scene.load(&snap);', '', 'play', 's_restore,s_window'),
    ('play makes undo steps', 'src/undo.zig', '    if (frozen) return;\n    defer collect();', '    defer collect();', 'play', 's_restore,s_window'),
    ('a kept play is no step', 'src/play.zig', '        undo.strokeStep("Play", null);', '', 'play', 's_restore,s_window'),
    ('the pointer never locked', 'src/wlext.zig', '        @import("play.zig").lock_fn = &lockPointer;', '', 'play', 's_window'),
    ('relative motion ignored', 'src/wlext.zig', '            @import("play.zig").look(ux * (1.0 / 256.0), uy * (1.0 / 256.0));', '            _ = ux + uy;', 'play', 's_window'),
    # --- the trees and the graphs
    ('NTRE not read', 'src/bee.zig', '    @import("ntree.zig").read(ntre orelse "");', '', 'logic', 's_files,s_play'),
    ('node counts past 48 kept', 'src/ntree.zig', '        if (nodes(r) > NT_MAXN) wr32(r, GR_N, 0);', '', 'logic', 's_damaged'),
    ('no budget', 'src/logic.zig', '    if (budget <= 0) {', '    if (budget <= -1000000) {', 'logic', 's_storm'),
    ('leave fires as enter', 'src/logic.zig', '                        1 => !now and was, // leave', '                        1 => now and !was, // leave', 'logic', 's_nodes'),
    ('a message to everyone', 'src/logic.zig', '            if (mq[m].to != 0 and mq[m].to != in.obj) continue;', '', 'logic', 's_nodes'),
    ('a hit every step', 'src/logic.zig', '                    if (in.flags & 4 != 0) continue; // (touching last step too: no)', '', 'logic', 's_nodes'),
    ('a logic modifier makes geometry go', 'src/mods.zig', '        if (d.flags & 1 == 0 or !ported(d.kind) or d.kind == LOGIC) continue;\n        if (d.kind == ARMATURE) {', '        if (d.flags & 1 == 0 or !ported(d.kind)) continue;\n        if (d.kind == LOGIC) return null;\n        if (d.kind == ARMATURE) {', 'logic', 's_mods'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# the copy builds as the sources do: the UI library next to it (build.zig.zon:
# ../BeeZigUi), and the project's zig (mise.toml) found from the project
_zui = os.path.join(os.path.dirname(ROOT), 'BeeZigUi')
if os.path.isdir(_zui) and not os.path.exists(os.path.join(W, 'BeeZigUi')):
    os.symlink(_zui, os.path.join(W, 'BeeZigUi'))
_mz = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT, capture_output=True, text=True,  # (mise's own installs: the real home, read only)
                     env=dict(os.environ, HOME=__import__('pwd').getpwuid(os.getuid()).pw_dir)) if shutil.which('mise') else None
ZIG = _mz.stdout.strip() if _mz is not None and _mz.returncode == 0 and _mz.stdout.strip() else 'zig'


def one(k):
    name, fn, old, new, suite, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        cpu = os.environ.get('BEE_CPU', '12')
        r = subprocess.run(['taskset', '-c', cpu, ZIG, 'build', '--release=fast', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, PLAY_ONLY=scen, LOGIC_ONLY=scen, BEEPLAY_TMP=W)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/{suite}.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(f'{W}/zc', ignore_errors=True)


res = {}
for k in range(len(M)):
    res[k] = one(k)
    print(f'{res[k][1]:9} {res[k][0]}: {res[k][2]}', flush=True)
caught = sum(1 for r in res.values() if r[1] == 'caught')
print(f'play mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
