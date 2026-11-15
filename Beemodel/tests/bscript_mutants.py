#!/usr/bin/env python3
"""Each guard of tests/bscript.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing. (Since
bscript.py runs BeeModel alone, only the guards a clean-run, limit, file,
console, undo or macro check can see are here: values only a comparison with
the original caught are gone.)

    python3 tests/bscript_mutants.py WORKDIR [jobs=2] [name...]   (WORKDIR under /tmp)
"""
import concurrent.futures, os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
B, L, S = 'src/bscript.zig', 'src/bs_lang.zig', 'src/bs_scene.zig'
M = [  # name, file, old, new, the sections that must fail
    # the compiler
    ('a builtin takes one argument more', B, 'if (argc < s.min or argc > s.max)', 'if (argc < s.min or argc > s.max + 1)', 'unported'),
    # the VM's budgets
    ('a few steps fewer', B, 'const STEP_MAX: u64 = 500000000;', 'const STEP_MAX: u64 = 499999990;', 'limits'),
    ('a smaller text heap', B, 'const SH_SIZE = 1048576;', 'const SH_SIZE = 1048576 - 4096;', 'limits'),
    ('one call deeper', B, 'if (fp >= FR_N - 1) return fail(e_recursion, "");', 'if (fp >= FR_N) return fail(e_recursion, "");', 'limits'),
    # files, the command line
    ('--run: 65535 bytes still read', B, 'if (st.size >= SRC_MAX - 1) {', 'if (st.size > SRC_MAX - 1) {', 'run'),
    ('--run: an empty file runs', B, 'if (st.mode & linux.S.IFMT == linux.S.IFDIR or st.size == 0) return cantRead(path);', 'if (st.mode & linux.S.IFMT == linux.S.IFDIR) return cantRead(path);', 'run'),
    ('--eval: exit 0 after an error', 'src/main.zig', 'const rc = if (std.mem.eql(u8, args[1], "--eval")) bs.eval(args[2], false) else bs.runFile(args[2]);', 'const rc: u8 = if (std.mem.eql(u8, args[1], "--eval")) bs.eval(args[2], false) & 0 else bs.runFile(args[2]);', 'run'),
    # the console
    ('console: mistyped ids run as BeeScript', 'src/editors.zig', 'return dots > 0;', 'return dots > 99;', 'console'),
    ('console: new = 5 is the word new', 'src/editors.zig', "if (arg[0] == '=' and (arg.len == 1 or arg[1] != '=')) return true;", '', 'console'),
    ('console: Tab completes nothing', 'src/editors.zig', 'pub fn consoleTab() void {', 'pub fn consoleTab() void {\n    if (true) return;', 'console'),
    ('console: a leak a run (vmove copies never dropped)', S, 'const c = scene.cloneMesh(mi) orelse return null;', 'const c = scene.cloneMesh(mi) orelse return null;\n    if (@import("alloc.zig").A.alloc(u8, 64 << 10)) |lost| @memset(lost, 1) else |_| {}', 'leak'),
    # macros
    ('macro: OPF_UNDO operators not recorded', B, 'if (std.mem.eql(u8, u, id)) return true;', 'if (std.mem.eql(u8, u, id) and id.len > 999) return true;', 'window'),
    ('macro: G not recorded', 'src/xform.zig', '@import("bscript.zig").macroTransform(@intFromEnum(mode) + 1);', '', 'window'),
    # undo: the whole run one step, also from the console
    ('undo: a save in a run makes a step', B, 'undo.frozen = true; // the whole run is one undo step', '', 'window'),
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
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, BS_ONLY=sec, BEE_CPU=os.environ.get('BEE_CPU', '10'))
        r = subprocess.run([sys.executable, '-u', f'{HERE}/bscript.py', f'{d}/out/bin/beemodel', '20', '4242'],
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
