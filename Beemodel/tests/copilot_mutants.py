#!/usr/bin/env python3
"""Each guard of tests/copilot.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that section of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/copilot_mutants.py WORKDIR [name...]   (WORKDIR under /tmp)

The fuzz section runs with each mutant too: COPILOT_FUZZ (default 150).
The builds (release: small, the quota of /tmp) run one after the other and so do
the tests: they pin BeeModel to BEE_CPU (default 14). (Gone since BeeModel
stopped being a port: the banner's place and text a few pixels off, a node
input's kind named otherwise - only the original's pixels and words caught them.)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the sections that must fail
    ('describe_graph: links not read', 'src/copilot.zig', 'if (lk & 0xffff != 0) {', 'if (false) {', 'json'),
    ('node_types: outputs from 1', 'src/copilot.zig', '            w.raw("{\\"index\\":");\n            w.int(@intCast(c));', '            w.raw("{\\"index\\":");\n            w.int(@intCast(c + 1));', 'json'),
    ('the prompt without its goal', 'src/copilot.zig', 'for ([_][]const u8{ prompt_1, goal, prompt_2 }) |s| {', 'for ([_][]const u8{ prompt_1, goal[0..0], prompt_2 }) |s| {', 'json'),
    ('bee://graphs without the proposal', 'src/copilot.zig', '    w.raw("],\\"proposal\\":");\n    w.raw(state_json[@intFromEnum(state)]);\n    w.char(\'}\');\n}\n\n// ---- prompts', '    w.raw("]}");\n}\n\n// ---- prompts', 'json'),
    ('a second propose_begin allowed', 'src/copilot.zig', 'if (state == .building or state == .waiting) {\n            mcp.fail', 'if (false) {\n            mcp.fail', 'proposal'),
    ('the proposal not one step', 'src/copilot.zig', '        undo.groupBegin(); // everything from here', '        // everything from here', 'proposal'),
    ('revert keeps the changes', 'src/copilot.zig', '        if (@import("ops.zig").byId("edit.undo")) |i| @import("mcp.zig").runOp(i, "");', '', 'proposal'),
    ('Enter while building accepts', 'src/copilot.zig', 'if (state == .waiting and (k == ui.KEY.ENTER', 'if ((k == ui.KEY.ENTER', 'proposal'),
    ('keypad Enter not taken', 'src/copilot.zig', ' or k == ui.KEY.KPENTER)) {', ')) {', 'proposal'),
    ('undo inside a proposal', 'src/mcp.zig', '    if (undo.grouped()) return app.log("  undo / redo wait', '    if (false) return app.log("  undo / redo wait', 'proposal'),
    ('the banner\'s buttons not clickable', 'src/copilot.zig', '    if (ui.press(ida, acc, ui.LMB)) {', '    if (false and ui.press(ida, acc, ui.LMB)) {', 'proposal'),
    ('the header has no Accept', 'src/agent.zig', '        @import("copilot.zig").headerButtons(salt, x, y);', '', 'proposal'),
    ('the banner not in the view\'s key', 'src/viewport.zig', '        h.update(std.mem.asBytes(&cp.state));', '', 'look'),
    ('propose_begin needs edit', 'src/copilot.zig', '        if (std.mem.eql(u8, n, tool)) return 0;', '        if (std.mem.eql(u8, n, tool)) return if (std.mem.eql(u8, tool, "propose_begin")) 1 else 0;', 'perm'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
bad = []
for k, (name, fn, old, new, sec) in enumerate(M):
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copytree(f'{ROOT}/tests', f'{d}/tests')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        if os.path.exists(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            print(f'  ?    {name}: the code is not there', flush=True)
            bad.append(name)
            continue
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            print(f'  ?    {name}: it does not build: {r.stderr[-300:]}', flush=True)
            bad.append(name)
            continue
        e = dict(os.environ, COPILOT_ONLY=sec, BEE_CPU=os.environ.get('BEE_CPU', '14'))
        r = subprocess.run([sys.executable, '-u', f'{d}/tests/copilot.py', f'{d}/out/bin/beemodel'],
                           env=e, capture_output=True, text=True, timeout=3600)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        st = 'ok' if fails else 'LIVE'
        print(f'  {st:4} {name}: ' + (f'{len(fails)} failed in {sec}: {fails[0].strip()[:100]}' if fails else f'nothing in {sec} failed'), flush=True)
        if not fails:
            bad.append(name)
    finally:
        shutil.rmtree(d, ignore_errors=True)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
