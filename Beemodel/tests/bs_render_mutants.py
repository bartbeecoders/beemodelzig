#!/usr/bin/env python3
"""Each guard of tests/bs_render.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/bs_render_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

(One job by default: each copy's build is ~1 GB of binaries and caches.)
"""
import concurrent.futures, os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
R, I = 'src/bs_render.zig', 'src/images.zig'
M = [  # name, file, old, new, the sections that must fail
    # images
    ('imgpixel: the channels swapped', R, 'return bs.num(@floatFromInt(e.b8[at][c]));', 'return bs.num(@floatFromInt(e.b8[at][c ^ 1]));', 'images'),
    ('imgpixel: HDR alpha 0', R, 'if (c == 3) return bs.num(1);', 'if (c == 3) return bs.num(0);', 'images'),
    ('imgpixel: the last column outside', R, 'if (x >= e.img.w or y >= e.img.h or c >= 4) return bs.num(-1);', 'if (x + 1 >= e.img.w or y >= e.img.h or c >= 4) return bs.num(-1);', 'images'),
    ('imgsize: negative axis is the width', R, 'const n: u32 = if (ax == 0) img.w else img.h;', 'const n: u32 = if (ax <= 0) img.w else img.h;', 'images'),
    ('image: the same file found again', R, 'const i = images.loadNew(path) catch return bs.fail(e_image, p0);', 'const i = images.load(path) catch return bs.fail(e_image, p0);', 'images'),
    # render, render_frames
    ('render: 0 samples traced as 1', R, 'if (spp == 0) return zeroSamples(path, path0, @intCast(w), @intCast(h));', '', 'render'),
    ('render: 600 wide by default', R, 'var w: i32 = 640;', 'var w: i32 = 600;', 'render'),
    ('render: a negative width rendered', R, 'if (w <= 0 or h <= 0) return false;', 'if (w == 0 or h == 0) return false;', 'render'),
    ('render: ~/BeeModel not made by file.save', 'src/files.zig', 'if (!headless or std.mem.startsWith(u8, d, "/tmp/")) _ = @import("spawn.zig").ensureDir(d);', '_ = d;', 'render'),
    ('render_frames: first after last renders', 'src/video.zig', 'if (first > last) return null;', 'if (first > last + 1) return null;', 'frames'),
    ('render_frames: the range by default from the next', R, 'var v = [6]i32{ fr.start, fr.end,', 'var v = [6]i32{ fr.start + 1, fr.end,', 'frames'),
    # (not a mutant: the folder's trailing slashes dropped - a//0001.png is the same file)
    # probes, the lightmap
    # (not here since BeeModel stopped being compared with the original: values only
    # it could tell; probesample's direction and ray offset, lmsample's distance,
    # texel corners and v; vgeo's 300 + L and 400 + L; image names' length, dots and
    # numbering from .000)
    ('probe(6): a layer of the grid', R, 'n +%= @bitCast(p.res[0] *% p.res[1] *% p.res[2]);', 'n +%= @bitCast(p.res[0] *% p.res[1]);', 'probes'),
    ('probeinfo: from 0', R, 'const n = (try int(a[0])) -% 1;', 'const n = try int(a[0]);', 'probes'),
    ('probeinfo: the half size for the centre', R, '2...4 => p.cen[@intCast(w - 2)],', '2...4 => p.half[@intCast(w - 2)],', 'probes'),
    ('lightmap(4): the width', R, '4 => @bitCast(lightmap.spp),', '4 => @bitCast(lightmap.w),', 'probes'),
    # cluster DAGs
    ('vgeo: never out of date', 'src/vgeo.zig', 'return if (base.vg_had) 3 else 0;', 'return 0;', 'vgeo'),
    ('vgeo: cleared stays out of date', 'src/vgeo.zig', 'if (scene.meshes[mi]) |*me| me.vg_had = false;', '_ = mi;', 'vgeo'),
    ('vgeo: a file\'s DAG not attached', 'src/bee.zig', 'if (scene.meshes[mi]) |*me| me.vg_had = true;', '_ = mi;', 'vgeo'),
    ('vgeo: crack check off', R, 'if (ku == 12) return bs.num(if (vgeo.check(d)) 1 else 0);', 'if (ku == 12) return bs.num(0);', 'vgeo'),
    ('vgstat(16): -1 before a check', 'src/vgdraw.zig', 'var vs_crack: i32 = 0;', 'var vs_crack: i32 = -1;', 'vgeo'),
    # the GPU helper
    ('gpu(1) on the CPU: 1', R, '1 => gpu.typeOf(),', '1 => 1,', 'gpu'),
    ('gpu(6): this render not counted after it ends', R, '6 => @intFromBool(gpupt.on or gpupt.why == .gpu),', '6 => @intFromBool(gpupt.on),', 'gpu'),
    ('gpu(2): runs not counted', 'src/gpupt.zig', '    n_runs +%= 1;\n', '', 'gpu'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, sec = M[k]
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
        gpu = sec == 'gpu'
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc'] + ([] if gpu else ['-Dgpu=false']), cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        exe = f'{d}/out/bin/beemodel'
        if r.returncode != 0:
            # (the copy into out may hit a disk quota: the cache's binary then)
            made = [f'{d}/zc/o/{x}/beemodel' for x in os.listdir(f'{d}/zc/o')] if os.path.isdir(f'{d}/zc/o') else []
            made = [x for x in made if os.path.exists(x)]
            if 'error:' in r.stderr.replace('DiskQuota', '') and 'DiskQuota' not in r.stderr or not made:
                errs = [ln for ln in r.stderr.splitlines() if 'error:' in ln]
                return name, '?', 'it does not build: ' + ' | '.join(errs[:2])[:300]
            exe = max(made, key=os.path.getmtime)
            if gpu:
                hp = [f'{d}/zc/o/{x}/beemodel-gpu' for x in os.listdir(f'{d}/zc/o') if os.path.exists(f'{d}/zc/o/{x}/beemodel-gpu')]
                if hp:
                    os.link(hp[0], os.path.join(os.path.dirname(exe), 'beemodel-gpu'))
        else:
            shutil.rmtree(f'{d}/zc', ignore_errors=True)  # (the quota: the binary is in out)
        e = dict(os.environ, BR_ONLY=sec, BR_TMP=d)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/bs_render.py', exe, '20', '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {sec}: {fails[0].strip()[:90]}' if fails else f'nothing in {sec} failed')
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
