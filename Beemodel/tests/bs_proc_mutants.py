#!/usr/bin/env python3
"""Each guard of tests/bs_proc.py and tests/bs_lib.py shown failing: the code
it guards (src/bs_proc.zig, src/wfc.zig, src/bs_lib.zig, the reference
image's view) broken one thing at a time in a copy of the sources; the part
of the suite that guards it must then fail. A mutant that survives is a test
that passes on nothing. (Since the suites stopped comparing with the
assembly original, only breakage they can see on their own is here: a safety
panic, a library that does not read back.)

    python3 tests/bs_proc_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

Each mutant is a debug build (about 1.2 GB on disk while it runs): keep jobs low.
"""
import concurrent.futures, os, shutil, subprocess, sys, time
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
P, F, L = 'src/bs_proc.zig', 'src/wfc.zig', 'src/bs_lib.zig'
M = [  # name, file, old, new, the suite and its sections that must fail
    # curves
    ('cpos: a fourth axis', P, 'or axis >= 3) return bs.nil;', 'or axis >= 4) return bs.nil;', 'proc:curves'),
    # wave function collapse
    ('wfc: 17 tiles', P, 'if (nt >= 16) return bs.fail(e_wfc_tiles, "");', 'if (nt >= 17) return bs.fail(e_wfc_tiles, "");', 'proc:wfc'),
    # the library
    ('libinfo: users by the fourth letter', L, 'const users = what.len > 4 and what[4] == \'s\';', 'const users = what.len > 3 and what[3] == \'s\';', 'lib'),
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
        for _ in range(6):  # (a full disk - other builds - is waited out, the cache made again)
            r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
            if r.returncode == 0 or not any(w in r.stderr for w in ('DiskQuota', 'NoSpaceLeft', 'panic')):
                break
            shutil.rmtree(f'{d}/zc', ignore_errors=True)
            time.sleep(60)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        shutil.rmtree(f'{d}/zc', ignore_errors=True)  # (the disk: the binary is all that is needed)
        suite, _, only = sec.partition(':')
        e = dict(os.environ, BS_ONLY=only, BEE_CPU=os.environ.get('BEE_CPU', '0-13'))
        r = subprocess.run([sys.executable, '-u', f'{HERE}/bs_{suite}.py', f'{d}/out/bin/beemodel', '4', '4242'], env=e, capture_output=True, text=True)
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
print(f'mutants {len(M)}, caught {len(M) - len(bad)}, survivors {len(bad)} {bad}')
sys.exit(1 if bad else 0)
