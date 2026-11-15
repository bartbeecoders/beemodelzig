#!/usr/bin/env python3
"""Each guard of tests/vc.py shown failing: the code it guards broken, one thing
at a time, in a copy of the sources; that part of the suite must then fail. A
mutant that survives is a test that passes on nothing.

    python3 tests/vc_mutants.py WORKDIR [jobs=3] [name...]   (WORKDIR under /tmp)

The copies and their builds go to WORKDIR/m<N> (removed after), a cache shared
in WORKDIR/zc; the window sections (pinned to BEE_CPU) run one mutant at a time.
"""
import concurrent.futures, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# the project's zig by its full path, asked before the HOME of our own (mise
# looks in the real one; its shim finds no version in the copies: no mise.toml there)
try:
    _z = subprocess.run(['mise', 'which', 'zig'], capture_output=True, text=True, cwd=ROOT).stdout.strip()
except OSError:
    _z = ''
ZIG = [_z if _z else 'zig']
import temphome  # noqa: F401,E402 (a HOME of its own)

W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 3
V, E, P = 'src/vc.zig', 'src/versions.zig', 'src/viewport.zig'
M = [  # name, file, old, new, the sections that must fail
    ('hash: rotated 22', V, 'h = std.math.rotl(u64, h, 23);', 'h = std.math.rotl(u64, h, 22);', 'flow'),
    ('refs: the merge not kept', V, 'if (mergeid != 0) {\n        try out.appendSlice(A, "merge ");', 'if (false) {\n        try out.appendSlice(A, "merge ");', 'flow'),
    ('three-way: ours taken for theirs', V, 'if (mfDiff(oe, be) & bit == 0) {', 'if (mfDiff(oe, be) & bit != 0) {', 'flow'),
    ('merge base: none found', V, 'if (std.mem.indexOfScalar(u64, mine[0..n], c) != null) return c;', 'if (std.mem.indexOfScalar(u64, mine[0..n], c) != null) return 0;', 'flow'),
    ('commit: always a new one', V, 'if (parent != 0 and mergeid == 0 and unchangedSince(parent, mh)) return say(s_nochange);', '', 'flow'),
    ('nothing changed: by hash only', V, 'return sameManifest(&mf_now, &other);', 'return false;', 'cross,stale'),
    ('manifest: no name compare', V, 'if (!std.mem.eql(u8, cstr(a[MF_NAME..][0..32]), cstr(b[MF_NAME..][0..32]))) r |= P_NAME;', '', 'flow,random'),
    ('manifest: its counts not checked', V, 'if (no > MF_MAXO or nc > MF_MAXC) return false;\n    if (MF_HDR + @as(usize, no) * MF_SZ + @as(usize, nc) * 16 > d.len) return false;', '_ = &no;\n    _ = &nc;', 'damaged'),
    ('mesh blob: offsets past the loops read', V, 'if (e > nl) return null;', '', 'damaged'),
    ('conflict row: always theirs', V, 'if (c.state == 1) "ours" else "theirs"', '"theirs"', 'flow'),
    ('resolve: the number off by one', V, '@as(i64, @intFromFloat(v)) - 1', '@as(i64, @intFromFloat(v))', 'flow'),
    ('merge: their uid not kept', V, '        scene.objects[i].uid = uid;\n', '', 'flow,random'),
    ('switch: the history starts again', V, '_ = bee.load(pb[0..p.len], files.viewForFile()) catch return false;', '_ = bee.load(pb[0..p.len], files.viewForFile()) catch return false;\n    @import("undo.zig").restart();', 'undo'),
    ('panel: 360 wide', V, '    pw = 370;\n', '    pw = 360;\n', 'window'),
    ('panel: ours and theirs swapped', V, 'cfSettle(k, if (x < bx + 55) 1 else 2);', 'cfSettle(k, if (x < bx + 55) 2 else 1);', 'window'),
    ('viewport: its cache keeps the diff', P, '    h.update(std.mem.asBytes(&@import("vc.zig").stateWord())); // (versions: the diff, the merge panel)\n', '', 'window'),
    ('editor: the typed message lost', E, '        if (ui.edit_id == msg_wid) {\n            msg_len', '        if (false) {\n            msg_len', 'editor'),
    ('editor: a row does not switch', E, 'runLater("vc.switch", nm);', 'runLater("vc.log", nm);', 'editor'),
]
want = [a for a in sys.argv[2:] if not a.isdigit()]
if want:
    M = [x for x in M if x[0] in want]


def one(k):
    name, fn, old, new, scen = M[k]
    d = os.path.join(W, f'm{k}')
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        shutil.copy(f'{ROOT}/build.zig.zon', d)   # (its ../BeeZigUi: WORKDIR/BeeZigUi, a link)
        if os.path.isdir(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([*ZIG, 'build', '-p', f'{d}/out', '--cache-dir', os.path.join(W, 'zc')], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, VC_ONLY=scen, VC_RANDOM='4')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/vc.py', f'{d}/out/bin/beemodel'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:100]}' if fails else f'nothing in {scen} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


os.makedirs(W, exist_ok=True)
if not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), f'{W}/BeeZigUi')
bad = []
win = [k for k, m in enumerate(M) if m[4] in ('window', 'editor', 'undo')]
rest = [k for k in range(len(M)) if k not in win]
res = {}
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for k, r in zip(rest, ex.map(one, rest)):
        res[k] = r
for k in win:   # (one at a time: they share the pinned CPU)
    res[k] = one(k)
for k in range(len(M)):
    name, st, msg = res[k]
    print(f'  {st:4} {name}: {msg}', flush=True)
    if st != 'ok':
        bad.append(name)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
