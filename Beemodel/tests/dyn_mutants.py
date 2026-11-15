#!/usr/bin/env python3
"""Each guard of tests/dyntopo.py and tests/multires.py shown failing: the code it guards
broken, one thing at a time, in a copy of the sources; that part of a suite must then
fail. A mutant that survives is a test that passes on nothing.

Left out, as they change nothing that can be seen: the merged valence (3 + 3 is a
tetrahedron, which the neighbours' valence refuses anyway), the vertex lock (a collapse
marks both rings changed, which refuses the same), the remesh's grab test (a grab never
comes through doDab), a level limit of 7 (a plan stops at 6), the scene's own mark of
the blocks (every block in use is in a step: strokes and operators push one), the
longest edge at a remesh's end (it only widens which leaves
are looked at, and the leaves that matter touch the sphere by their boxes), the list room
in sculpt_build (remesh grows the pool itself).

Left out too since the original is gone (2026-11-14): mutants of the remesh's
thresholds and bookkeeping (finer, coarser, the collapse and split rules, the
merge, the owners) that only a triangle-for-triangle match with the original
caught.

    python3 tests/dyn_mutants.py WORKDIR [--jobs N] [name...]   (each builds: minutes)
"""
import os, shutil, subprocess, sys, threading
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
args = sys.argv[1:]
jobs = 1
if '--jobs' in args:
    k = args.index('--jobs')
    jobs = int(args[k + 1])
    del args[k:k + 2]
W = os.path.abspath(args[0])
want = args[1:]
D, R, U = 'src/dyntopo.zig', 'src/multires.zig', 'src/undo.zig'
M = [  # name, file, old, new, suite:scenarios
    ('detail: a floor of 1', D, 'const dmin: f32 = 2.0;', 'const dmin: f32 = 1.0;', 'dyntopo s_ui'),
    ('detail: no ceiling', D, 'const dmax: f32 = 64.0;', 'const dmax: f32 = 640.0;', 'dyntopo s_ui'),
    ('the detail in pixels', D, 'remesh(rr, r * detail / sc.radius);', 'remesh(rr, r * detail / 50);', 'dyntopo s_same'),
    ('remesh under the mask', D, 'if (!on or sc.brush_now == sc.GRAB or sc.brush_now == sc.MASK) return;', 'if (!on or sc.brush_now == sc.GRAB) return;', 'dyntopo s_same'),
    ('finish: boxes stale', D, 'sc.nodeBox(l);', '', 'dyntopo s_midstroke'),
    ('finish: lists stale', D, 'if (sub == 0) n.vown = c;', '', 'dyntopo s_midstroke'),
    ('commit: a step behind', D, 'scene.objects[i].mesh = mi;', 'scene.objects[i].mesh = mi;\n    undo_.absorbMesh(i);', 'dyntopo s_undo'),
    ('toggle: mask lost', D, 'carryMask(sc.nv, null);', '', 'dyntopo s_midstroke s_same'),
    ('toggle: in a stroke', D, 'if (!sc.on or sc.land or sc.stroking) return;', 'if (!sc.on or sc.land) return;', 'dyntopo s_midstroke'),
    ('toggle: at a level', D, 'if (sc.ext.owns.?()) return', 'if (false) return', 'multires s_undo'),
    ('memory: no room made', D, 'if (!reserve(sc.nv + total * 4 + 64, sc.nt + total * 8 + 64)) return noMem();', '', 'dyntopo s_robust'),
    ('memory: pools not grown', D, 'if (!pool(&sc.tri, tri_used + 2 * cap + 64 * @as(u64, nl))) return noMem();', '', 'dyntopo s_robust'),
    ('memory: vertex pool not grown', D, 'if (!pool(&sc.vl, sc.nvl + 6 * cap + 64 * @as(u64, nl))) return noMem();', '', 'dyntopo s_robust'),
    ('memory: smoothing left behind', D, 'if (sc.acc.len > 0 and !grow([4]f32, &sc.acc, c)) return false;', '', 'dyntopo s_robust'),
    ('memory: nothing said', D, 'app.toast(.warn, "dyntopo: out of memory", .{});', '', 'dyntopo s_robust'),
    ('undo: stale copy', 'src/sculpt.zig', 'if (on and mesh_mi == mi and me.serial == mesh_serial and pos != v.ptr) {', 'if (false) {', 'dyntopo s_undo'),
    ('sculpt: rebuilt each frame', 'src/sculpt.zig', 'if (ext.dyn == null or !ext.dyn.?()) {', 'if (true) {', 'dyntopo s_midstroke'),
    ('ui: Detail always', 'src/sculptui.zig', 'if (dyntopo.on) { // dynamic topology: its detail', 'if (true) { // dynamic topology: its detail', 'dyntopo s_ui'),
    ('ui: the line silent', 'src/sculptui.zig', 'w.print("dyntopo {d} px", .{stroke.trunc32(dyntopo.detail)}) catch {};', '', 'dyntopo s_ui'),
    ('ui: the level silent', 'src/sculptui.zig', 'if (multires.owns()) {', 'if (false) {', 'multires s_ui'),
    ('levels: rounded', R, 'stroke.trunc32(mods.getF(d, 1))', '@as(i32, @intFromFloat(@round(std.math.clamp(mods.getF(d, 1), -9, 9))))', 'multires s_robust'),
    ('levels: rounded up', 'src/mods.zig', 'setF(d, q, if (p.int) roundEven(c) else c);', 'setF(d, q, if (p.int) @round(c) else c);', 'multires s_levels'),
    ('fingerprint ignored', R, 'return if (std.mem.eql(u32, &b.db, &c)) b else null;', 'return if (c[0] != 0) b else null;', 'multires s_stack'),
    ('prune: never', 'src/mods.zig', 'multires.prune(oi); // (multires detail that no longer fits)', '', 'multires s_stack'),
    ('find: anywhere in the stack', R, 'return if (d.kind == mods.MULTIRES) d else null;', 'if (d.kind == mods.MULTIRES) return d;', 'multires s_stack'),
    ('find: the disabled too', R, 'if (d.flags & 1 == 0) continue;\n        return if', 'return if', 'multires s_stack'),
    ('sculpted past dyntopo', R, 'if (dyntopo.on) return null;', '', 'multires s_undo'),
    ('stroke: the old block lost', R, 'if (old) |b| @memcpy(nb.verts[0..b.verts.len], b.verts);', '', 'multires s_sculpt'),
    ('stroke: the wrong level', R, 'const lev = nb.verts[mr_off..];', 'const lev = nb.verts[0..];', 'multires s_sculpt'),
    ('stroke: the block shrinks', R, 'if (old) |b| n = @max(n, b.verts.len);', 'if (old) |b| n = @max(n, b.verts.len / 2);', 'multires s_sculpt'),
    ('stroke: not told it took', R, 'kd = stamp(o); // (the copy is that, as sculpted)', '', 'multires s_sculpt'),
    ('stroke: in place', 'src/sculpt.zig', 'if (ext.stroke_end) |f| f(); // multires', '// multires', 'multires s_sculpt'),
    ('propagate: only some', 'src/subsurf.zig', 'for (0..3) |c| e[c] = g[c] - q[c];\n                q.* = g;', 'for (0..3) |c| e[c] = g[c] - q[c];', 'multires s_sculpt'),
    ('displace: past the block', 'src/subsurf.zig', '} else if (@as(usize, done) <= mr.disp.len) {', '} else if (mr.disp.len > 0) {', 'multires s_robust'),
    ('displace: level one only', 'src/subsurf.zig', 'mr.off = done;\n        done += n;', 'mr.off = 0;\n        done += n;', 'multires s_sculpt'),
    ('shows: stale after a stroke', 'src/mods.zig', 'h.update(std.mem.asBytes(&multires.stamp(o))); // (its displacements)', '', 'multires s_undo'),
    ('shows: not displaced in place', 'src/mods.zig', 'multires.evalInto(oi, asP(base), e.plan.?, me.verts) catch return base;', '', 'multires s_undo'),
    ('undo: blocks freed', U, 'if (o.mesh) |mi| used[mi] = true;\n            if (o.mres) |mi| used[mi] = true;\n        }\n    }\n}\n\n/// Steps', 'if (o.mesh) |mi| used[mi] = true;\n        }\n    }\n}\n\n/// Steps', 'multires s_undo'),
    ('undo: blocks outside the budget', U, 'for ([2]?u16{ o.mesh, o.mres }) |h| {', 'for ([1]?u16{o.mesh}) |h| {', 'multires s_undo'),
    ('undo: no step for a block', 'src/scene.zig', 'a.mesh == b.mesh and a.mres == b.mres and', 'a.mesh == b.mesh and', 'multires s_ui'),
    ('file: not written', 'src/bee.zig', '@import("multires.zig").writeChunk(&b);', '', 'multires s_files'),
    ('file: not read', 'src/bee.zig', 'if (mres) |c| @import("multires.zig").readChunk(c, ours);', '', 'multires s_files'),
    ('file: the wrong object', R, 'if (ours[idx]) |i| {', 'if (ours[ours.len - 1 - idx]) |i| {', 'multires s_files'),
    ('file: past the chunk', R, 'if (size > d.len - o) return;', '', 'multires s_robust'),
    ('button: Subdivide hides the level', R, '_ = mods.set(oi, k, "level", x);', '', 'multires s_ui'),
    ('button: Subdivide does not stop', R, '_ = mods.set(oi, k, "levels", x);', 'mods.setF(&scene.objects[oi].mods.m[k], 0, x);', 'multires s_ui'),
    ('button: Propagate dead', 'src/editors.zig', '@import("multires.zig").opDown();', '', 'multires s_ui'),
    ('words: the toast changed', R, 'app.toast(.warn, "multires: select a mesh with a multires modifier", .{});', 'app.toast(.warn, "no", .{});', 'multires s_ui'),
]
lock = threading.Lock()
queue = [m for m in M if not want or m[0] in want]
survivors = []


def work(w):
    root = f'{W}/{w}'
    src = f'{root}/src'
    os.makedirs(src, exist_ok=True)
    if not os.path.exists(f'{src}/build.zig'):
        shutil.copytree(f'{ROOT}/src', f'{src}/src', dirs_exist_ok=True)
        shutil.copy(f'{ROOT}/build.zig', src)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', src)
    while True:
        with lock:
            if not queue:
                return
            name, fn, old, new, scen = queue.pop(0)
        subprocess.run(['rsync', '-a', '--delete', f'{ROOT}/src/', f'{src}/src/'])
        p = f'{src}/{fn}'
        t = open(p).read()
        if old not in t:
            with lock:
                print(f'  ?    {name}: the code is not there', flush=True)
                survivors.append(name)
            continue
        t = t.replace(old, new, 1)
        if 'undo_.' in new:
            t = t.replace('const A = @import("alloc.zig").A;', 'const A = @import("alloc.zig").A;\nconst undo_ = @import("undo.zig");', 1)
        open(p, 'w').write(t)
        ui_link(src)
        r = subprocess.run(['zig', 'build', '-Dgpu=false', '-p', f'{root}/out', '--cache-dir', f'{root}/zc', '--release=off'], cwd=src, capture_output=True, text=True)
        shutil.rmtree(f'{root}/zc/o', ignore_errors=True)  # (a binary a mutant: the disk is not endless)
        if r.returncode != 0:
            with lock:
                print(f'  ?    {name}: it does not build\n{r.stderr[-300:]}', flush=True)
                survivors.append(name)
            continue
        suite, *rest = scen.split()
        ss, only = [], ''
        for x in rest:
            a, _, b = x.partition(':')
            ss.append(a)
            only = b or only
        try:
            r = subprocess.run([sys.executable, '-u', f'{HERE}/{suite}.py', f'{root}/out/bin/beemodel', '4', '1', *ss], env=dict(os.environ, SCULPT_ONLY=only, BEERIG_TMP=os.environ.get('BEERIG_TMP', '/tmp'), BEE_CPU=str(4 + w)), capture_output=True, text=True, timeout=1500)
            fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln or 'Traceback' in ln]
            rc = r.returncode
            tail = r.stderr[-90:]
        except subprocess.TimeoutExpired:
            fails, rc, tail = ['a hang'], 1, ''
        with lock:
            if fails or rc != 0:
                print(f'  ok   {name}: {len(fails)} failed in {scen}: {fails[0].strip()[:90] if fails else tail}', flush=True)
            else:
                print(f'  LIVE {name}: nothing in {scen} failed', flush=True)
                survivors.append(name)


th = [threading.Thread(target=work, args=(i,)) for i in range(jobs)]
for x in th:
    x.start()
for x in th:
    x.join()
print('survivors', len(survivors), survivors)
shutil.rmtree(W, ignore_errors=True)
sys.exit(1 if survivors else 0)
